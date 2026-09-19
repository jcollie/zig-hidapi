// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Linux backend: `/dev/hidraw*` driven by the `HIDIOC*` ioctls of
//! `uapi/linux/hidraw.h`, and `/sys/class/hidraw/*` read directly for
//! everything that can be learned without opening a device.
//!
//! Every syscall here goes through `std.os.linux` rather than through libc, so
//! a Linux build of this library links no C at all. That is not true of the
//! other backends -- Zig 0.16 ships no raw-syscall layer for FreeBSD or Darwin
//! and Windows has none to ship -- which is why the choice belongs to the
//! backend and not to the library.
//!
//! The declarations this file has to carry are listed in `contract.zig`.
//! Nothing outside `src/backend/` imports it directly.

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.hidapi_linux);

const ioctl = @import("linux/ioctl.zig");
const sysfs = @import("linux/sysfs.zig");

const descriptor = @import("../descriptor.zig");
const io_op = @import("../io_op.zig");
const errors = @import("../errors.zig");
const DeviceId = @import("../DeviceId.zig");
const DeviceInfo = @import("../DeviceInfo.zig");
const Options = @import("../Enumerator.zig").Options;
const OpenOptions = @import("../Device.zig").OpenOptions;
const Str = @import("../Str.zig");

/// The largest report descriptor the kernel will hand out, so a buffer this
/// size always fits one.
pub const max_report_descriptor_len = ioctl.HID_MAX_DESCRIPTOR_SIZE;

/// Map an `errno` onto the portable error set, logging what it was.
///
/// Every failure in this file goes through here, which is what keeps the log
/// line identical across operations and keeps the mapping in one place to
/// argue about.
fn mapErrno(what: []const u8, e: linux.E) errors.DeviceError {
    log.warn("{s}: {s}", .{ what, @tagName(e) });
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT, .NXIO => error.DeviceNotFound,
        // A hidraw node whose device has gone answers ENODEV, and a transfer
        // that was in flight when it went answers EIO. Both mean stop rather
        // than look again.
        .NODEV, .SHUTDOWN, .IO => error.DeviceDisconnected,
        .NOMEM, .MFILE, .NFILE => error.SystemResources,
        else => error.DeviceRefused,
    };
}

/// Map what `file_read_streaming` answers onto the portable read errors.
///
/// `EndOfStream` is the interesting one. A hidraw descriptor whose device has
/// been unplugged reads zero bytes rather than failing, which is how a read
/// loop finds out the device is gone -- and it has to be told apart from a
/// legitimately empty report, which a device may also send.
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

/// An open `hidraw` device.
///
/// Caller-owned and used through a pointer: `Device` above this holds one of
/// these inline, so the library allocates nothing, and the address stays the
/// caller's to keep. On Linux that buys little -- the whole state is a file
/// descriptor -- but on macOS the run-loop callback is handed this pointer and
/// keeps it for the life of the device, so the shape is not optional there and
/// one signature for all four backends is worth a pointer indirection here.
pub const Device = struct {
    fd: linux.fd_t,

    /// Open the device `id` names, which on Linux is a `/dev/hidraw*` path.
    ///
    /// `options` is accepted and ignored: Linux needs no report queue of its
    /// own, because hidraw already buffers input reports in the kernel.
    pub fn open(
        self: *Device,
        io: std.Io,
        id: DeviceId,
        options: OpenOptions,
    ) errors.OpenError!void {
        _ = options;
        var p = try io.concurrent(_open, .{id});
        defer _ = p.cancel(io) catch {};
        self.* = .{ .fd = try p.await(io) };
    }

    pub fn close(self: *Device, io: std.Io) void {
        var p = io.concurrent(_close, .{self.fd}) catch return;
        defer p.cancel(io);
        p.await(io);
        self.fd = -1;
    }

    /// The device as `std.Io` sees it.
    ///
    /// `nonblocking` tracks how the descriptor was actually opened, because
    /// `Io` branches on it: claiming a blocking descriptor is non-blocking is
    /// documented as unrecoverable in `Io.Threaded`, not merely wrong.
    fn file(self: *const Device) std.Io.File {
        return .{ .handle = self.fd, .flags = .{ .nonblocking = false } };
    }

    /// Read an input report from the interrupt IN endpoint, waiting until the
    /// device sends one.
    pub fn read(self: *Device, io: std.Io, buf: []u8) errors.ReadError![]u8 {
        const result = try io.operate(.{ .file_read_streaming = .{
            .file = self.file(),
            .data = &.{buf},
        } });
        return buf[0..try mapRead(result.file_read_streaming)];
    }

    /// Read an input report, giving up after `timeout`.
    ///
    /// `null` means nothing arrived in time. A zero duration therefore makes
    /// this a non-blocking poll, which is why there is no separate
    /// non-blocking mode to set: a mode flag would be a second way to express
    /// something the timeout already says, and every backend would have to
    /// honour both.
    ///
    /// Note that `null` and a zero-length report are different answers. A HID
    /// device may legitimately send a report with no data, so the two cannot
    /// share a representation.
    pub fn readTimeout(
        self: *Device,
        io: std.Io,
        buf: []u8,
        timeout: std.Io.Timeout,
    ) errors.ReadError!?[]u8 {
        // `Io.Threaded` polls the descriptor with a deadline before it issues
        // the read, so this is a real timeout on a blocking descriptor and
        // needs no `O_NONBLOCK`; `Io.Uring` submits it as a linked timeout.
        const result = io_op.operateTimeout(io, .{ .file_read_streaming = .{
            .file = self.file(),
            .data = &.{buf},
        } }, timeout) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => return error.Canceled,
            error.ConcurrencyUnavailable => return error.SystemResources,
        };
        return buf[0..try mapRead(result.file_read_streaming)];
    }

    /// Write an output report to the first OUT endpoint, or to the control
    /// endpoint when the device has none.
    pub fn write(self: *Device, io: std.Io, data: []const u8) errors.WriteError!usize {
        const result = try io.operate(.{ .file_write_streaming = .{
            .file = self.file(),
            .data = &.{data},
        } });
        return result.file_write_streaming catch |err| {
            log.warn("write: {s}", .{@errorName(err)});
            return switch (err) {
                error.AccessDenied => error.AccessDenied,
                error.SystemResources => error.SystemResources,
                error.InputOutput, error.Unexpected => error.DeviceDisconnected,
                else => error.DeviceRefused,
            };
        };
    }

    /// Issue `request` with `arg`, reporting a failing syscall through
    /// `mapErrno`.
    fn call(
        self: *Device,
        io: std.Io,
        what: []const u8,
        request: u32,
        arg: usize,
    ) (errors.DeviceError || std.Io.Cancelable)!usize {
        const result = try io.operate(.{ .device_io_control = .{
            .file = self.file(),
            .code = request,
            .arg = @ptrFromInt(arg),
        } });
        // The POSIX arm of `device_io_control` hands back what `ioctl`
        // returned, with a negative value carrying the negated `errno`.
        if (result.device_io_control < 0) {
            return mapErrno(what, @enumFromInt(-result.device_io_control));
        }
        return @intCast(result.device_io_control);
    }

    /// The shared body of the three string ioctls.
    ///
    /// All three behave the same way: they copy a NUL terminated string into
    /// the caller's buffer, clamped to its length, and return the number of
    /// bytes copied including the terminator.
    fn string(
        self: *Device,
        io: std.Io,
        what: []const u8,
        comptime request: fn (len: ioctl.Size) u32,
        buf: []u8,
    ) (errors.DeviceError || std.Io.Cancelable)!Str {
        // No useful buffer is too large to name, so clamp rather than fail:
        // the result is the same string, truncated, which `Str` records.
        const request_len = std.math.cast(ioctl.Size, buf.len) orelse
            std.math.maxInt(ioctl.Size);
        const len = try self.call(io, what, request(request_len), @intFromPtr(buf.ptr));

        // A zero length means `buf` was empty and a lone terminator means the
        // string was; either way the device reported nothing.
        if (len == 0 or (len == 1 and buf[0] == 0)) return .empty;
        // The ioctl clamps its copy to the buffer and does not terminate a
        // string it had to truncate, so a missing terminator means it did not
        // fit. Keep what arrived and say it was cut.
        if (buf[len - 1] != 0) {
            var s: Str = .init(buf[0..len]);
            s.truncated = true;
            return s;
        }
        return .init(buf[0 .. len - 1]);
    }

    /// The size in bytes of the device's HID report descriptor.
    pub fn getReportDescriptorLen(self: *Device, io: std.Io) errors.DescriptorError!u32 {
        var size: u32 = 0;
        _ = try self.call(io, "HIDIOCGRDESCSIZE", ioctl.HIDIOCGRDESCSIZE, @intFromPtr(&size));
        return size;
    }

    /// Copy the device's HID report descriptor into `buf`.
    pub fn getReportDescriptor(
        self: *Device,
        io: std.Io,
        buf: []u8,
    ) errors.DescriptorError![]const u8 {
        const size = try self.getReportDescriptorLen(io);
        if (buf.len < size) return error.BufferTooSmall;
        // `hidraw_report_descriptor` carries the whole 4 KiB buffer by value
        // rather than a pointer, so this is worth keeping off a small stack.
        var rd: ioctl.hidraw_report_descriptor = .init(size);
        _ = try self.call(io, "HIDIOCGRDESC", ioctl.HIDIOCGRDESC, @intFromPtr(&rd));
        @memcpy(buf[0..size], rd.value[0..size]);
        return buf[0..size];
    }

    /// Fill in everything the open device itself can answer.
    ///
    /// This is the ioctl route rather than the sysfs one, because a caller
    /// holding an open device has already paid for the permission it needs.
    /// It answers less than enumeration does: the manufacturer, product and
    /// serial strings live on the USB device rather than on the HID one, and
    /// `HIDIOCGRAWNAME` returns the two run together, so `manufacturer` is
    /// left unreported here and `product` carries the combined name.
    pub fn getInfo(
        self: *Device,
        io: std.Io,
        out: *DeviceInfo,
    ) (errors.DeviceError || std.Io.Cancelable)!void {
        out.* = .empty;

        var raw: ioctl.hidraw_devinfo = .init;
        _ = try self.call(io, "HIDIOCGRAWINFO", ioctl.HIDIOCGRAWINFO, @intFromPtr(&raw));
        out.vendor_id = raw.vendor;
        out.product_id = raw.product;
        out.native_bus = @truncate(@intFromEnum(raw.bustype));
        out.bus_type = sysfs.busType(out.native_bus);

        var buf: [Str.max_len]u8 = undefined;
        out.product = try self.string(io, "HIDIOCGRAWNAME", ioctl.HIDIOCGRAWNAME, &buf);
        out.serial_number = try self.string(io, "HIDIOCGRAWUNIQ", ioctl.HIDIOCGRAWUNIQ, &buf);
        out.physical_location = try self.string(io, "HIDIOCGRAWPHYS", ioctl.HIDIOCGRAWPHYS, &buf);
    }

    /// Send a feature report over the control endpoint as a Set_Report
    /// transfer.
    pub fn sendFeatureReport(
        self: *Device,
        io: std.Io,
        data: []const u8,
    ) errors.ReportError!usize {
        const len = std.math.cast(ioctl.Size, data.len) orelse return error.ReportTooLarge;
        return self.call(io, "HIDIOCSFEATURE", ioctl.HIDIOCSFEATURE(len), @intFromPtr(data.ptr));
    }

    /// Request a feature report over the control endpoint.
    pub fn getFeatureReport(self: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
        const len = std.math.cast(ioctl.Size, buf.len) orelse return error.ReportTooLarge;
        const got = try self.call(
            io,
            "HIDIOCGFEATURE",
            ioctl.HIDIOCGFEATURE(len),
            @intFromPtr(buf.ptr),
        );
        return buf[0..got];
    }

    /// Request an input report over the control endpoint, rather than waiting
    /// for one on the interrupt IN endpoint as `read` does.
    pub fn getInputReport(self: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
        const len = std.math.cast(ioctl.Size, buf.len) orelse return error.ReportTooLarge;
        const got = try self.call(
            io,
            "HIDIOCGINPUT",
            ioctl.HIDIOCGINPUT(len),
            @intFromPtr(buf.ptr),
        );
        return buf[0..got];
    }
};

fn _open(id: DeviceId) errors.OpenError!linux.fd_t {
    var path_buf: [DeviceId.max_len + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{id.slice()}) catch
        return error.DeviceIdTooLong;

    const rc = linux.open(
        path,
        .{
            .ACCMODE = .RDWR,
            .APPEND = true,
            .NONBLOCK = false,
        },
        0,
    );
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| mapErrno("open", e),
    };
}

fn _close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

/// Walks `/sys/class/hidraw`.
///
/// Nothing here opens a device, which is the point: the class directory is
/// world readable where the nodes are not, so an unprivileged process with no
/// udev rule can still see what is attached. It also means enumeration costs
/// no permission and cannot disturb a device another process is using.
pub const Enumerator = struct {
    dir: std.Io.Dir,
    it: std.Io.Dir.Iterator,
    options: Options,
    bufs: Bufs,
    /// Set when there is nothing to iterate, so that `next` answers without
    /// touching an iterator that was never initialised.
    exhausted: bool,

    /// Scratch this backend will not work below: one report descriptor, one
    /// `uevent`, and room for the attribute strings.
    pub const min_scratch = max_report_descriptor_len + uevent_len + Str.max_len;

    /// Comfortable scratch, and what `Enumerator.recommended_scratch` is.
    pub const recommended_scratch = 16 * 1024;

    /// `uevent` is a handful of short lines; sysfs reports every attribute as
    /// one page regardless, and reads short.
    const uevent_len = 4096;

    const Bufs = struct {
        uevent: []u8,
        report_descriptor: []u8,
        attribute: []u8,
    };

    pub fn init(
        self: *Enumerator,
        io: std.Io,
        scratch: []u8,
        options: Options,
    ) errors.EnumerateError!void {
        if (scratch.len < min_scratch) return error.BufferTooSmall;

        const dir = std.Io.Dir.openDirAbsolute(io, sysfs.class_path, .{ .iterate = true }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // No class directory means no hidraw driver, which is an empty
            // list rather than a failure -- the same answer a machine with no
            // HID devices gives.
            else => {
                self.* = .{
                    .dir = .{ .handle = -1 },
                    .it = undefined,
                    .options = options,
                    .bufs = undefined,
                    .exhausted = true,
                };
                return;
            },
        };

        var rest = scratch;
        const uevent = rest[0..uevent_len];
        rest = rest[uevent_len..];
        const rd = rest[0..max_report_descriptor_len];
        rest = rest[max_report_descriptor_len..];
        const attribute = rest[0..Str.max_len];

        self.* = .{
            .dir = dir,
            .it = dir.iterate(),
            .options = options,
            .bufs = .{ .uevent = uevent, .report_descriptor = rd, .attribute = attribute },
            .exhausted = false,
        };
    }

    pub fn deinit(self: *Enumerator, io: std.Io) void {
        if (!self.exhausted or self.dir.handle != -1) self.dir.close(io);
        self.* = undefined;
    }

    /// Fill `out` with the next device, or answer `false` when there are none
    /// left.
    pub fn next(
        self: *Enumerator,
        io: std.Io,
        out: *DeviceInfo,
    ) errors.EnumerateError!bool {
        if (self.exhausted) return false;
        while (true) {
            const entry = self.it.next(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return false,
            } orelse return false;

            if (try self.fill(io, entry.name, out)) return true;
        }
    }

    /// Everything read for one `hidrawN` entry. `false` means skip it: either
    /// it does not look like a HID device, or the caller filtered it out.
    fn fill(
        self: *Enumerator,
        io: std.Io,
        node: []const u8,
        out: *DeviceInfo,
    ) errors.EnumerateError!bool {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

        const uevent_path = std.fmt.bufPrint(&path_buf, "{s}/device/uevent", .{node}) catch
            return false;
        const text = try sysfs.readAttribute(io, self.dir, uevent_path, self.bufs.uevent) orelse
            return false;
        const attrs = sysfs.parseUevent(text);

        out.* = .empty;
        out.vendor_id = attrs.vendor;
        out.product_id = attrs.product;
        out.native_bus = attrs.bus;
        out.bus_type = sysfs.busType(attrs.bus);

        if (!out.matches(self.options.vendor_id, self.options.product_id)) return false;

        out.id = DeviceId.init(
            std.fmt.bufPrint(&path_buf, "/dev/{s}", .{node}) catch return false,
        ) catch return false;

        if (self.options.strings) {
            out.product = .init(attrs.name);
            out.serial_number = .init(attrs.uniq);
            out.physical_location = .init(attrs.phys);

            // Only USB has the ancestors these live on. On anything else
            // `device/../..` belongs to a different subsystem entirely, so the
            // files are absent and reading them would be meaningless even if
            // they were not.
            if (sysfs.isUsb(attrs)) {
                if (try sysfs.usbAttribute(io, self.dir, node, "manufacturer", self.bufs.attribute)) |m|
                    out.manufacturer = .init(m);
                // The USB device's own product string is the better answer
                // when there is one: `HID_NAME` is it with the manufacturer
                // glued to the front.
                if (try sysfs.usbAttribute(io, self.dir, node, "product", self.bufs.attribute)) |p|
                    out.product = .init(p);
                if (try sysfs.usbAttribute(io, self.dir, node, "serial", self.bufs.attribute)) |s|
                    out.serial_number = .init(s);
                if (try sysfs.usbAttribute(io, self.dir, node, "bcdDevice", self.bufs.attribute)) |b|
                    out.release_number = std.fmt.parseInt(u16, b, 16) catch 0;
                out.interface_number = try sysfs.usbInterfaceNumber(io, self.dir, node);
            }
        }

        if (self.options.usages) {
            const rd_path = std.fmt.bufPrint(&path_buf, "{s}/device/report_descriptor", .{node}) catch
                return true;
            if (try sysfs.readAttribute(io, self.dir, rd_path, self.bufs.report_descriptor)) |bytes| {
                if (descriptor.firstUsage(bytes)) |u| {
                    out.usage_page = u.page;
                    out.usage = u.id;
                }
            }
        }

        return true;
    }
};

test {
    std.testing.refAllDecls(@This());
}
