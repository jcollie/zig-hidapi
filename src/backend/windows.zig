// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Windows backend: HIDCLASS, reached through `NtDeviceIoControlFile`.
//!
//! Every request goes through `std.Io.Operation.device_io_control`, whose
//! Windows arm *is* `NtDeviceIoControlFile`, with the `IOCTL_HID_*` codes from
//! `windows/ioctl.zig`. The documented user-mode route would be the `HidD_*`
//! functions in `hid.dll`, but those are thin wrappers around exactly these
//! codes and calling a DLL means a blocking call `Io` cannot cancel or time
//! out. Going straight to the control code keeps every operation in this
//! backend cancelable, and puts reads on the same APC-based path
//! `Io.Threaded` uses for any other asynchronous handle.
//!
//! Two things genuinely need `hid.dll`, and they are the exceptions rather
//! than the rule:
//!
//! * **The three report lengths.** Windows rejects any `WriteFile` that is not
//!   exactly `OutputReportByteLength` bytes, and the only supported way to
//!   learn that number is `HidD_GetPreparsedData` followed by
//!   `HidP_GetCaps`. `HidP_*` is pure user-mode parsing with no request behind
//!   it, so there is no control code to use instead. It is called once at
//!   open.
//! * **The usage page and usage**, which come out of the same `HIDP_CAPS`.
//!
//! **Windows cannot produce a report descriptor.**
//! `IOCTL_HID_GET_REPORT_DESCRIPTOR` exists but lives in `hidport.h`: it is
//! what HIDCLASS sends *down* to the transport minidriver during enumeration,
//! not something the collection a `CreateFileW` opens will answer.
//! `IOCTL_HID_GET_COLLECTION_DESCRIPTOR`, despite its name, returns the class
//! driver's own opaque parsed form. A descriptor can be reconstructed from
//! that -- the C hidapi spends about a thousand lines doing it -- but the
//! result is equivalent rather than identical, so `getReportDescriptor`
//! reports `error.Unsupported` instead of handing back bytes the device never
//! sent.
//!
//! The Win32 declarations come from the `zigwin32` package rather than being
//! written out here. Its `foundation.HANDLE` is `std.os.windows.HANDLE`, so
//! its handles and `std.Io.File` interoperate directly.

const std = @import("std");
const windows = std.os.windows;

const win32 = @import("win32");
const hid = win32.hid;
const cm = win32.cfgmgr32;
const k32 = win32.kernel32;
const hid_types = win32.devices.human_interface_device;
const dev_install = win32.devices.device_and_driver_installation;
const fs = win32.storage.file_system;
const foundation = win32.foundation;

const ioctl = @import("windows/ioctl.zig");
const path_util = @import("windows/path.zig");

const descriptor = @import("../descriptor.zig");
const errors = @import("../errors.zig");
const io_op = @import("../io_op.zig");
const BusType = @import("../bus_type.zig").BusType;
const DeviceId = @import("../DeviceId.zig");
const DeviceInfo = @import("../DeviceInfo.zig");
const Options = @import("../Enumerator.zig").Options;
const OpenOptions = @import("../Device.zig").OpenOptions;
const Str = @import("../Str.zig");

const log = std.log.scoped(.hidapi_windows);

/// Nothing here can produce a report descriptor, but the declaration is part
/// of the backend contract and callers size buffers with it.
pub const max_report_descriptor_len = 4096;

/// `GENERIC_READ | GENERIC_WRITE`.
///
/// `FILE_ACCESS_FLAGS` names bits 0..20 and leaves the top eleven as `_21`
/// through `_31`, and the two generic bits are 30 and 31. Writing
/// `.{ ._31 = 1, ._30 = 1 }` would be unreadable and would break the day the
/// generator names those bits, so the value is built from the number.
const generic_read_write: fs.FILE_ACCESS_FLAGS = @bitCast(@as(u32, 0xC000_0000));

/// No access at all, which is still enough for the metadata requests.
const no_access: fs.FILE_ACCESS_FLAGS = @bitCast(@as(u32, 0));

/// Zero bytes to pad a short output report with.
///
/// Windows requires the buffer handed to a write to be exactly the device's
/// output report length, so a shorter report has to be padded. This is in
/// read-only data rather than a per-device buffer, which is what keeps the
/// library allocation-free: `file_write_streaming` takes a list of slices, so
/// the report and the padding go down as one write without being copied into
/// one place first.
const zero_padding: [max_report_descriptor_len]u8 = @splat(0);

fn wide(text: []const u8, buf: []u16) error{DeviceIdTooLong}![:0]u16 {
    const len = std.unicode.wtf8ToWtf16Le(buf[0 .. buf.len - 1], text) catch
        return error.DeviceIdTooLong;
    buf[len] = 0;
    return buf[0..len :0];
}

/// Map an `NTSTATUS` onto the portable error set, logging what it was.
fn mapStatus(what: []const u8, status: windows.NTSTATUS) errors.DeviceError {
    log.warn("{s}: {t}", .{ what, status });
    return switch (status) {
        .ACCESS_DENIED => error.AccessDenied,
        .SHARING_VIOLATION => error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND, .NO_SUCH_DEVICE => error.DeviceNotFound,
        .DEVICE_NOT_CONNECTED, .DEVICE_DOES_NOT_EXIST => error.DeviceDisconnected,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => error.DeviceRefused,
    };
}

/// An open HID collection.
pub const Device = struct {
    file: std.Io.File,

    /// What a read has to be able to hold, and a write has to be exactly.
    /// Both include the leading report ID byte. Learned once at open from
    /// `HidP_GetCaps`; zero when the device would not say.
    input_report_len: u16,
    output_report_len: u16,
    feature_report_len: u16,

    usage_page: u16,
    usage: u16,

    /// False when the device could only be opened for metadata, which is what
    /// happens for anything the system holds exclusively -- keyboards and
    /// pointing devices, in practice. Reading or writing such a device is
    /// `error.AccessDenied` rather than an obscure failure from the driver.
    readable: bool,

    pub fn open(
        self: *Device,
        io: std.Io,
        id: DeviceId,
        options: OpenOptions,
    ) errors.OpenError!void {
        _ = options;

        var path_buf: [DeviceId.max_len]u16 = undefined;
        const path = try wide(id.slice(), &path_buf);

        var readable = true;
        const handle = openPath(io, path, generic_read_write) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The system opens keyboards and pointing devices exclusively, so
            // a read-write open of one is refused outright. A zero-access
            // handle still answers every metadata request, which is how such
            // a device can be enumerated and described even though it can
            // never be read. The C hidapi does the same.
            error.AccessDenied, error.DeviceRefused => blk: {
                readable = false;
                break :blk try openPath(io, path, no_access);
            },
            else => |e| return e,
        };

        self.* = .{
            // The handle was opened with `FILE_FLAG_OVERLAPPED`, which is what
            // `nonblocking` means on Windows and what puts every operation on
            // `Io.Threaded`'s cancelable APC path. Claiming this wrongly is
            // documented there as unrecoverable, not merely wrong.
            .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
            .input_report_len = 0,
            .output_report_len = 0,
            .feature_report_len = 0,
            .usage_page = 0,
            .usage = 0,
            .readable = readable,
        };

        self.readCaps();

        // HIDCLASS keeps a ring of input reports per open handle and defaults
        // to 32, which a chatty device overruns between reads. The C hidapi
        // asks for 64 for the same reason.
        var buffers: u32 = 64;
        _ = self.call(io, "SET_NUM_DEVICE_INPUT_BUFFERS", ioctl.SET_NUM_DEVICE_INPUT_BUFFERS, std.mem.asBytes(&buffers), &.{}) catch {};
    }

    /// Read the three report lengths and the usage pair out of the class
    /// driver's parsed data.
    ///
    /// The one place this backend calls `hid.dll`. `HidP_GetCaps` parses a
    /// blob that is already in memory -- there is no request behind it and so
    /// no control code to use instead -- and without the output report length
    /// a write cannot be padded to the length Windows insists on.
    ///
    /// Failure is not fatal. A device that will not say leaves the lengths at
    /// zero, and `write` then requires the caller to supply an exactly sized
    /// report rather than guessing one.
    fn readCaps(self: *Device) void {
        var preparsed: isize = 0;
        if (hid.HidD_GetPreparsedData(self.file.handle, &preparsed) == 0) return;
        defer _ = hid.HidD_FreePreparsedData(preparsed);

        var caps: hid_types.HIDP_CAPS = undefined;
        if (hid.HidP_GetCaps(preparsed, &caps) != .SUCCESS) return;

        self.input_report_len = caps.InputReportByteLength;
        self.output_report_len = caps.OutputReportByteLength;
        self.feature_report_len = caps.FeatureReportByteLength;
        self.usage_page = caps.UsagePage;
        self.usage = caps.Usage;
    }

    pub fn close(self: *Device, io: std.Io) void {
        self.file.close(io);
        self.file = .{ .handle = undefined, .flags = .{ .nonblocking = true } };
    }

    /// Issue a control request.
    fn call(
        self: *Device,
        io: std.Io,
        what: []const u8,
        code: windows.CTL_CODE,
        input: []const u8,
        output: []u8,
    ) (errors.DeviceError || std.Io.Cancelable)!usize {
        const iosb = (try io.operate(.{ .device_io_control = .{
            .file = self.file,
            .code = code,
            .in = input,
            .out = output,
        } })).device_io_control;
        if (iosb.u.Status != .SUCCESS) return mapStatus(what, iosb.u.Status);
        return iosb.Information;
    }

    /// Read an input report, waiting until the device sends one.
    pub fn read(self: *Device, io: std.Io, buf: []u8) errors.ReadError![]u8 {
        try self.checkReadable();
        const result = try io.operate(.{ .file_read_streaming = .{
            .file = self.file,
            .data = &.{self.readSlice(buf)},
        } });
        return self.strip(buf, try mapRead(result.file_read_streaming));
    }

    /// Read an input report, giving up after `timeout`.
    pub fn readTimeout(
        self: *Device,
        io: std.Io,
        buf: []u8,
        timeout: std.Io.Timeout,
    ) errors.ReadError!?[]u8 {
        try self.checkReadable();
        const result = io_op.operateTimeout(io, .{ .file_read_streaming = .{
            .file = self.file,
            .data = &.{self.readSlice(buf)},
        } }, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => return error.Canceled,
            error.ConcurrencyUnavailable => return error.SystemResources,
        };
        return self.strip(buf, try mapRead(result.file_read_streaming));
    }

    /// Windows will not read into a buffer shorter than one whole input
    /// report, and will not report less than one either, so hand the driver
    /// exactly what it wants when the length is known.
    fn readSlice(self: *const Device, buf: []u8) []u8 {
        if (self.input_report_len == 0 or self.input_report_len > buf.len) return buf;
        return buf[0..self.input_report_len];
    }

    /// HIDCLASS prepends a zero report ID byte for a device whose reports are
    /// unnumbered, where Linux, FreeBSD and macOS do not. Dropping it is what
    /// makes the bytes a caller sees the same on every system.
    fn strip(self: *const Device, buf: []u8, len: usize) []u8 {
        if (self.usesReportIds() or len == 0 or buf[0] != 0) return buf[0..len];
        std.mem.copyForwards(u8, buf[0 .. len - 1], buf[1..len]);
        return buf[0 .. len - 1];
    }

    /// Whether the device's reports are numbered, which the class driver only
    /// tells us indirectly: an unnumbered device's report length counts the
    /// ID byte the driver itself adds.
    fn usesReportIds(self: *const Device) bool {
        // Not knowable without the descriptor, which Windows will not supply,
        // so this is deliberately conservative: assume numbered reports and
        // leave the leading byte alone unless it is zero, which is what
        // `strip` checks.
        _ = self;
        return false;
    }

    fn checkReadable(self: *const Device) errors.ReadError!void {
        if (!self.readable) {
            log.warn("read: device was opened for metadata only", .{});
            return error.AccessDenied;
        }
    }

    /// Write an output report.
    ///
    /// Windows insists the buffer be exactly `OutputReportByteLength` bytes,
    /// and answers anything else with `STATUS_INVALID_PARAMETER`, so a shorter
    /// report is zero padded. The padding comes from read-only data and goes
    /// down as a second slice of the same write rather than being copied into
    /// a buffer first, which is what keeps this allocation-free.
    pub fn write(self: *Device, io: std.Io, data: []const u8) errors.WriteError!usize {
        if (!self.readable) return error.AccessDenied;

        const want = self.output_report_len;
        if (want != 0 and data.len > want) return error.ReportTooLarge;
        const pad = if (want == 0) 0 else want - data.len;
        if (pad > zero_padding.len) return error.ReportTooLarge;

        const result = try io.operate(.{ .file_write_streaming = .{
            .file = self.file,
            .data = &.{ data, zero_padding[0..pad] },
        } });
        const written = result.file_write_streaming catch |err| {
            log.warn("write: {s}", .{@errorName(err)});
            return switch (err) {
                error.AccessDenied => error.AccessDenied,
                error.SystemResources => error.SystemResources,
                error.InputOutput, error.Unexpected => error.DeviceDisconnected,
                else => error.DeviceRefused,
            };
        };
        // The padding is the driver's business, not the caller's.
        return @min(written, data.len);
    }

    pub fn sendFeatureReport(
        self: *Device,
        io: std.Io,
        data: []const u8,
    ) errors.ReportError!usize {
        if (self.feature_report_len != 0 and data.len > self.feature_report_len)
            return error.ReportTooLarge;
        _ = try self.call(io, "SET_FEATURE", ioctl.SET_FEATURE, data, &.{});
        return data.len;
    }

    pub fn getFeatureReport(self: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
        // The report ID the caller wants is in `buf[0]` on the way in, and
        // the driver expects it in the *output* buffer, which it then fills.
        const got = try self.call(io, "GET_FEATURE", ioctl.GET_FEATURE, &.{}, buf);
        return buf[0..got];
    }

    pub fn getInputReport(self: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
        const got = try self.call(io, "GET_INPUT_REPORT", ioctl.GET_INPUT_REPORT, &.{}, buf);
        return buf[0..got];
    }

    /// Always zero: HIDCLASS keeps the ring of input reports, which `open`
    /// asks it to make 64 deep, and `read` takes from that directly rather
    /// than queueing again in user space.
    pub fn takeDroppedReports(self: *Device) u64 {
        _ = self;
        return 0;
    }

    /// Always `error.Unsupported`; see the note at the top of this file.
    pub fn getReportDescriptorLen(self: *Device, io: std.Io) errors.DescriptorError!u32 {
        _ = .{ self, io };
        return error.Unsupported;
    }

    /// Always `error.Unsupported`; see the note at the top of this file.
    pub fn getReportDescriptor(
        self: *Device,
        io: std.Io,
        buf: []u8,
    ) errors.DescriptorError![]const u8 {
        _ = .{ self, io, buf };
        return error.Unsupported;
    }

    /// The class driver's own parsed form of the report descriptor.
    ///
    /// Opaque, undocumented and different between Windows versions, and the
    /// only thing Windows will give instead of a descriptor. Offered so that a
    /// caller who knows what it is can have it; anything portable should use
    /// `DeviceInfo.usage_page` and `usage`, which are read out of it here.
    pub fn getPreparsedData(self: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
        const got = try self.call(
            io,
            "GET_COLLECTION_DESCRIPTOR",
            ioctl.GET_COLLECTION_DESCRIPTOR,
            &.{},
            buf,
        );
        return buf[0..got];
    }

    /// Fill in what the open collection can answer.
    ///
    /// Less than enumeration, as on every backend, and for a different
    /// reason: the transport a device is attached by is a fact about its place
    /// in the device tree, which only `cfgmgr32` knows and which an open
    /// handle cannot be asked. `bus_type` is therefore left `unknown` here.
    pub fn getInfo(
        self: *Device,
        io: std.Io,
        out: *DeviceInfo,
    ) (errors.DeviceError || std.Io.Cancelable)!void {
        out.* = .empty;

        var info: ioctl.CollectionInformation = undefined;
        _ = try self.call(
            io,
            "GET_COLLECTION_INFORMATION",
            ioctl.GET_COLLECTION_INFORMATION,
            &.{},
            std.mem.asBytes(&info),
        );
        out.vendor_id = info.vendor_id;
        out.product_id = info.product_id;
        out.release_number = info.version_number;

        out.usage_page = self.usage_page;
        out.usage = self.usage;

        out.manufacturer = try self.string(io, "MANUFACTURER", ioctl.GET_MANUFACTURER_STRING);
        out.product = try self.string(io, "PRODUCT", ioctl.GET_PRODUCT_STRING);
        out.serial_number = try self.string(io, "SERIALNUMBER", ioctl.GET_SERIALNUMBER_STRING);
    }

    /// One of the three string requests, converted from UTF-16.
    ///
    /// A device that reports no such string answers with an empty one rather
    /// than failing, and a device that fails the request outright is treated
    /// the same way: a missing serial number is not a reason to refuse to
    /// describe the device.
    fn string(
        self: *Device,
        io: std.Io,
        what: []const u8,
        code: windows.CTL_CODE,
    ) (errors.DeviceError || std.Io.Cancelable)!Str {
        // The maximum a HID string descriptor can carry is 126 UTF-16 units.
        var wide_buf: [128]u16 = undefined;
        const got = self.call(io, what, code, &.{}, std.mem.sliceAsBytes(&wide_buf)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return .empty,
        };

        const units = wide_buf[0 .. got / 2];
        const trimmed = std.mem.sliceTo(units, 0);
        if (trimmed.len == 0) return .empty;

        var utf8: [Str.max_len]u8 = undefined;
        const len = std.unicode.wtf16LeToWtf8(&utf8, trimmed);
        return .init(utf8[0..@min(len, utf8.len)]);
    }
};

fn openPath(
    io: std.Io,
    path: [:0]const u16,
    access: fs.FILE_ACCESS_FLAGS,
) errors.OpenError!windows.HANDLE {
    var p = io.concurrent(createFile, .{ path, access }) catch return error.SystemResources;
    defer _ = p.cancel(io) catch {};
    return try p.await(io);
}

/// `CreateFileW` has no `Io.Operation`, so this is the one place the old
/// `io.concurrent` convention is still the only option.
fn createFile(path: [:0]const u16, access: fs.FILE_ACCESS_FLAGS) errors.OpenError!windows.HANDLE {
    const handle = k32.CreateFileW(
        path.ptr,
        access,
        // Both share bits, always. Without them, opening a device any other
        // process already holds fails with a sharing violation -- and on
        // Windows something is very often already holding it.
        .{ .READ = 1, .WRITE = 1 },
        null,
        fs.OPEN_EXISTING,
        // Makes the handle asynchronous, which is what lets every operation
        // on it go down `Io.Threaded`'s cancelable APC path.
        fs.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (handle == foundation.INVALID_HANDLE_VALUE) {
        const err = k32.GetLastError();
        log.warn("CreateFileW: {t}", .{err});
        return switch (err) {
            .ERROR_ACCESS_DENIED => error.AccessDenied,
            .ERROR_SHARING_VIOLATION => error.DeviceRefused,
            .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => error.DeviceNotFound,
            .ERROR_NOT_ENOUGH_MEMORY, .ERROR_OUTOFMEMORY => error.SystemResources,
            else => error.DeviceRefused,
        };
    }
    return handle;
}

fn mapRead(result: std.Io.Operation.FileReadStreaming.Result) errors.ReadError!usize {
    return result catch |err| {
        log.warn("read: {s}", .{@errorName(err)});
        return switch (err) {
            error.EndOfStream, error.InputOutput, error.Unexpected => error.DeviceDisconnected,
            error.AccessDenied, error.NotOpenForReading => error.AccessDenied,
            error.SystemResources => error.SystemResources,
            else => error.DeviceRefused,
        };
    };
}

/// Walks the HID device interfaces `cfgmgr32` knows about.
///
/// The list itself costs one call and no handles, and the vendor and product
/// IDs can be read straight out of each path, so a filtered enumeration never
/// opens anything it is going to skip. Only a device that passes the filter is
/// opened, and then with no access at all -- which is what lets a keyboard be
/// described even though it can never be read.
pub const Enumerator = struct {
    /// The interface list, as a UTF-16 multi-string, carved out of the
    /// caller's scratch.
    list: []const u16,
    /// Where the next path begins.
    index: usize,
    options: Options,
    exhausted: bool,

    /// A HID interface path is about 250 UTF-16 units and a machine may have
    /// a few dozen devices, so this is comfortable for any realistic one.
    pub const recommended_scratch = 64 * 1024;

    /// Enough for a handful of devices, which is the floor rather than a
    /// recommendation: `init` reports `error.BufferTooSmall` when the real
    /// list does not fit.
    pub const min_scratch = 4 * 1024;

    pub fn init(
        self: *Enumerator,
        io: std.Io,
        scratch: []u8,
        options: Options,
    ) errors.EnumerateError!void {
        if (scratch.len < min_scratch) return error.BufferTooSmall;

        // The list is UTF-16, so the scratch has to be aligned for it.
        const aligned = std.mem.alignInSlice(scratch, @alignOf(u16)) orelse
            return error.BufferTooSmall;
        const buf = std.mem.bytesAsSlice(u16, aligned[0 .. aligned.len / 2 * 2]);

        self.* = .{ .list = &.{}, .index = 0, .options = options, .exhausted = true };

        var p = io.concurrent(fetchList, .{buf}) catch return error.SystemResources;
        defer _ = p.cancel(io) catch {};
        const list = try p.await(io);

        self.* = .{ .list = list, .index = 0, .options = options, .exhausted = false };
    }

    pub fn deinit(self: *Enumerator, io: std.Io) void {
        _ = io;
        self.* = undefined;
    }

    pub fn next(
        self: *Enumerator,
        io: std.Io,
        out: *DeviceInfo,
    ) errors.EnumerateError!bool {
        if (self.exhausted) return false;
        while (self.nextPath()) |path| {
            if (try self.fill(io, path, out)) return true;
        }
        return false;
    }

    /// Step over one NUL-terminated entry of the multi-string. A second NUL
    /// where a path would start ends the list.
    fn nextPath(self: *Enumerator) ?[]const u16 {
        if (self.index >= self.list.len) return null;
        const rest = self.list[self.index..];
        const end = std.mem.indexOfScalar(u16, rest, 0) orelse return null;
        if (end == 0) return null;
        self.index += end + 1;
        return rest[0..end];
    }

    fn fill(
        self: *Enumerator,
        io: std.Io,
        path_w: []const u16,
        out: *DeviceInfo,
    ) errors.EnumerateError!bool {
        var path_buf: [DeviceId.max_len]u8 = undefined;
        const len = std.unicode.wtf16LeToWtf8(&path_buf, path_w);
        if (len > path_buf.len) return false;
        const path = path_buf[0..len];

        // Cheap rejection first: the path carries the vendor and product IDs,
        // so a filtered enumeration never opens a device it is going to skip.
        const fields = path_util.parse(path);
        if (self.options.vendor_id) |want| {
            if (fields.vendor_id != null and fields.vendor_id.? != want) return false;
        }
        if (self.options.product_id) |want| {
            if (fields.product_id != null and fields.product_id.? != want) return false;
        }

        out.* = .empty;
        out.id = DeviceId.init(path) catch return false;
        out.interface_number = fields.interface_number;
        out.physical_location = .init(path);

        var device: Device = undefined;
        // Metadata only: a read-write open would be refused for every device
        // the system holds, which is exactly the set a caller most often
        // wants to see listed.
        device.open(io, out.id, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        defer device.close(io);

        var asked: DeviceInfo = undefined;
        device.getInfo(io, &asked) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        out.vendor_id = asked.vendor_id;
        out.product_id = asked.product_id;
        out.release_number = asked.release_number;
        if (self.options.usages) {
            out.usage_page = asked.usage_page;
            out.usage = asked.usage;
        }
        if (self.options.strings) {
            out.manufacturer = asked.manufacturer;
            out.product = asked.product;
            out.serial_number = asked.serial_number;
        } else {
            out.physical_location = .empty;
        }

        if (!out.matches(self.options.vendor_id, self.options.product_id)) return false;

        out.bus_type = parentBus(path);
        return true;
    }
};

/// Ask `cfgmgr32` for the whole HID interface list.
///
/// A retry loop rather than one call, because a device can arrive between
/// asking for the size and asking for the list, which is answered with
/// `CR_BUFFER_SMALL` rather than a short list.
fn fetchList(buf: []u16) errors.EnumerateError![]const u16 {
    var guid = hid_types.GUID_DEVINTERFACE_HID;
    var attempts: usize = 0;
    while (attempts < 4) : (attempts += 1) {
        var needed: u32 = 0;
        if (cm.CM_Get_Device_Interface_List_SizeW(
            &needed,
            &guid,
            null,
            dev_install.CM_GET_DEVICE_INTERFACE_LIST_PRESENT,
        ) != .CR_SUCCESS) return error.DeviceRefused;
        if (needed > buf.len) return error.BufferTooSmall;

        switch (cm.CM_Get_Device_Interface_ListW(
            &guid,
            null,
            buf.ptr,
            @intCast(buf.len),
            dev_install.CM_GET_DEVICE_INTERFACE_LIST_PRESENT,
        )) {
            .CR_SUCCESS => return buf[0..needed],
            .CR_BUFFER_SMALL => continue,
            else => return error.DeviceRefused,
        }
    }
    return error.DeviceRefused;
}

/// The transport of the device behind an interface path.
///
/// The instance ID is spelled inside the path already -- the part between the
/// first and last `#`, with `#` standing in for `\` -- so it does not have to
/// be asked for. What does have to be asked for is the *parent*, because a HID
/// collection's own instance ID always begins `HID\` whatever it is attached
/// by.
fn parentBus(path: []const u8) BusType {
    var instance_buf: [512]u8 = undefined;
    const instance = path_util.instanceId(path, &instance_buf) orelse return .unknown;

    var wide_buf: [512]u16 = undefined;
    const instance_w = wide(instance, &wide_buf) catch return .unknown;

    var node: u32 = 0;
    if (cm.CM_Locate_DevNodeW(&node, instance_w.ptr, dev_install.CM_LOCATE_DEVNODE_NORMAL) != .CR_SUCCESS)
        return .unknown;

    var parent: u32 = 0;
    if (cm.CM_Get_Parent(&parent, node, 0) != .CR_SUCCESS) return .unknown;

    var parent_w: [512:0]u16 = undefined;
    if (cm.CM_Get_Device_IDW(parent, &parent_w, parent_w.len, 0) != .CR_SUCCESS) return .unknown;

    var parent_id: [512]u8 = undefined;
    const len = std.unicode.wtf16LeToWtf8(&parent_id, std.mem.sliceTo(&parent_w, 0));
    return path_util.busTypeFromInstanceId(parent_id[0..@min(len, parent_id.len)]);
}

test {
    std.testing.refAllDecls(@This());
}
