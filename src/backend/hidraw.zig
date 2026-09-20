// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The half of a `hidraw` backend that Linux and FreeBSD share.
//!
//! FreeBSD's `hidraw(4)` implements the Linux request set deliberately --
//! `HIDIOCGRDESCSIZE`, `HIDIOCGRAWINFO`, `HIDIOCGFEATURE` and the rest, with
//! the same structures behind them -- so an open device behaves identically on
//! the two systems. What differs is the request *numbers*, because BSD and
//! Linux encode them differently and FreeBSD numbers its from group `'U'`
//! rather than `'H'`. That difference is a table, which is what this file is
//! parameterized by.
//!
//! What is not shared is enumeration. Linux reads `/sys/class/hidraw` and
//! opens nothing; FreeBSD has no sysfs and has to open each node to ask it
//! anything. Each backend keeps its own.
//!
//! Every call goes through `std.Io`: the open through `Io.Dir`, the reports
//! through `Io.Operation.file_read_streaming` and `file_write_streaming`, and
//! every ioctl through `Io.Operation.device_io_control`. There is not a raw
//! syscall in the file, which is also why it needs no `std.os.linux` and no
//! `std.c` and so can be shared between a backend that links libc and one that
//! does not.

const std = @import("std");

const errors = @import("../errors.zig");
const io_op = @import("../io_op.zig");
const DeviceId = @import("../DeviceId.zig");
const DeviceInfo = @import("../DeviceInfo.zig");
const OpenOptions = @import("../Device.zig").OpenOptions;
const Str = @import("../Str.zig");
const BusType = @import("../bus_type.zig").BusType;

/// The largest report descriptor either kernel will hand out.
pub const max_report_descriptor_len = 4096;

/// Zero: both kernels hand over the descriptor itself, so there is nothing to
/// rebuild and nowhere to need working memory.
pub const recommended_descriptor_scratch = 0;

/// What `HIDIOCGRAWINFO` fills in, laid out as `struct hidraw_devinfo`.
///
/// Identical on both systems. The kernels declare the vendor and product
/// fields signed; they are the same bits either way and a VID reads as an
/// unsigned number, so they are `u16` here.
pub const DevInfo = extern struct {
    bustype: u32,
    vendor: u16,
    product: u16,

    /// A zeroed value to hand to the ioctl. Zero is not one of the `BUS_*`
    /// values, so a device that answers always overwrites it.
    pub const zero: DevInfo = .{ .bustype = 0, .vendor = 0, .product = 0 };

    comptime {
        // Both kernels copy this in and out by size, so a layout that drifts
        // from the header has to fail the build rather than quietly exchange
        // the wrong bytes.
        std.debug.assert(@sizeOf(DevInfo) == 8);
    }
};

/// What `HIDIOCGRDESC` fills in, laid out as
/// `struct hidraw_report_descriptor`.
///
/// Over 4 KiB by value, so worth keeping off a small stack.
pub const ReportDescriptor = extern struct {
    size: u32,
    value: [max_report_descriptor_len]u8,

    /// A zeroed descriptor asking for `size` bytes, which has to be set from
    /// `HIDIOCGRDESCSIZE` before the call: the kernel copies out only as many
    /// bytes as this says.
    pub fn init(size: u32) ReportDescriptor {
        return .{ .size = size, .value = @splat(0) };
    }
};

/// The request numbers for one kernel.
///
/// The length-carrying requests are functions because the length is encoded
/// in the number itself.
pub const Requests = struct {
    GRDESCSIZE: u32,
    GRDESC: u32,
    GRAWINFO: u32,
    GRAWNAME: *const fn (len: u16) u32,
    GRAWPHYS: *const fn (len: u16) u32,
    GRAWUNIQ: *const fn (len: u16) u32,
    SFEATURE: *const fn (len: u16) u32,
    GFEATURE: *const fn (len: u16) u32,
    GINPUT: *const fn (len: u16) u32,
    /// The largest buffer a request number on this kernel can name: 14 bits
    /// on Linux for most architectures, 13 on FreeBSD.
    max_len: u16,
};

/// The bus a `BUS_*` value names.
///
/// FreeBSD's `sys/dev/evdev/input.h` carries the same values as Linux's
/// `uapi/linux/input.h`, byte for byte, so one table serves both.
///
/// Anything not listed is `other` rather than a reason to hide the device:
/// both kernels gain bus types over time.
pub fn busType(raw: u16) BusType {
    return switch (raw) {
        0x00 => .unknown,
        0x03 => .usb,
        0x05 => .bluetooth,
        0x06 => .virtual,
        0x18 => .i2c,
        0x1C => .spi,
        else => .other,
    };
}

/// Map an `errno` onto the portable error set, logging what it was.
///
/// Every failure in a `hidraw` backend goes through here, which keeps the log
/// line identical across operations and the mapping in one place to argue
/// about.
pub fn mapErrno(log: anytype, what: []const u8, e: std.posix.E) errors.DeviceError {
    log.warn("{s}: {s}", .{ what, @tagName(e) });
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT, .NXIO => error.DeviceNotFound,
        // A node whose device has gone answers ENODEV, and a transfer that
        // was in flight when it went answers EIO. Both mean stop rather than
        // look again.
        .NODEV, .SHUTDOWN, .IO => error.DeviceDisconnected,
        .NOMEM, .MFILE, .NFILE => error.SystemResources,
        else => error.DeviceRefused,
    };
}

/// An open `hidraw` device, for a kernel whose requests are `requests`.
pub fn Device(comptime requests: Requests, comptime scope: @TypeOf(.enum_literal)) type {
    return struct {
        const Self = @This();
        const log = std.log.scoped(scope);

        file: std.Io.File,

        /// Open the device `id` names, which on both systems is the path of a
        /// `/dev/hidraw*` node.
        ///
        /// `options` is accepted and ignored: neither kernel needs a report
        /// queue of this library's, because `hidraw` already buffers input
        /// reports -- 64 of them on both.
        pub fn open(
            self: *Self,
            io: std.Io,
            id: DeviceId,
            options: OpenOptions,
        ) errors.OpenError!void {
            _ = options;
            const file = std.Io.Dir.openFileAbsolute(io, id.slice(), .{
                .mode = .read_write,
                // A device node is not a directory, and saying so turns a
                // nonsense path into `error.IsDir` at open rather than into a
                // failing read later.
                .allow_directory = false,
            }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.FileNotFound, error.BadPathName, error.NameTooLong => return error.DeviceNotFound,
                error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
                error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => return error.SystemResources,
                error.DeviceBusy => return error.DeviceRefused,
                else => {
                    log.warn("open {s}: {s}", .{ id.slice(), @errorName(err) });
                    return error.DeviceRefused;
                },
            };
            self.* = .{ .file = file };
        }

        pub fn close(self: *Self, io: std.Io) void {
            self.file.close(io);
            self.file = .{ .handle = -1, .flags = .{ .nonblocking = false } };
        }

        /// Read an input report from the interrupt IN endpoint, waiting until
        /// the device sends one.
        pub fn read(self: *Self, io: std.Io, buf: []u8) errors.ReadError![]u8 {
            const result = try io.operate(.{ .file_read_streaming = .{
                .file = self.file,
                .data = &.{buf},
            } });
            return buf[0..try mapRead(result.file_read_streaming)];
        }

        /// Read an input report, giving up after `timeout`.
        pub fn readTimeout(
            self: *Self,
            io: std.Io,
            buf: []u8,
            timeout: std.Io.Timeout,
        ) errors.ReadError!?[]u8 {
            // `Io.Threaded` polls the descriptor with a deadline before it
            // issues the read, so this is a real timeout on a blocking
            // descriptor and needs no `O_NONBLOCK`; `Io.Uring` submits it as a
            // linked timeout.
            const result = io_op.operateTimeout(io, .{ .file_read_streaming = .{
                .file = self.file,
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
        pub fn write(self: *Self, io: std.Io, data: []const u8) errors.WriteError!usize {
            const result = try io.operate(.{ .file_write_streaming = .{
                .file = self.file,
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

        /// Issue `request` with `arg`.
        fn call(
            self: *Self,
            io: std.Io,
            what: []const u8,
            request: u32,
            arg: ?*anyopaque,
        ) (errors.DeviceError || std.Io.Cancelable)!usize {
            const result = try io.operate(.{ .device_io_control = .{
                .file = self.file,
                .code = request,
                .arg = arg,
            } });
            // The POSIX arm hands back what `ioctl` returned, with a negative
            // value carrying the negated `errno`.
            if (result.device_io_control < 0) {
                return mapErrno(log, what, @enumFromInt(-result.device_io_control));
            }
            return @intCast(result.device_io_control);
        }

        /// The shared body of the three string requests.
        ///
        /// All three copy a NUL terminated string into the caller's buffer,
        /// clamped to its length, and return the number of bytes copied
        /// including the terminator.
        fn string(
            self: *Self,
            io: std.Io,
            what: []const u8,
            comptime request: *const fn (len: u16) u32,
            buf: []u8,
        ) (errors.DeviceError || std.Io.Cancelable)!Str {
            // No useful buffer is too large for a request number to name, so
            // clamp rather than fail: the result is the same string,
            // truncated, which `Str` records.
            const request_len: u16 = @intCast(@min(buf.len, requests.max_len));
            const len = try self.call(io, what, request(request_len), buf.ptr);

            // A zero length means `buf` was empty and a lone terminator means
            // the string was; either way the device reported nothing.
            if (len == 0 or (len == 1 and buf[0] == 0)) return .empty;
            // The request clamps its copy to the buffer and does not
            // terminate a string it had to truncate, so a missing terminator
            // means it did not fit. Keep what arrived and say it was cut.
            if (buf[len - 1] != 0) {
                var s: Str = .init(buf[0..len]);
                s.truncated = true;
                return s;
            }
            return .init(buf[0 .. len - 1]);
        }

        /// The size in bytes of the device's HID report descriptor.
        pub fn getReportDescriptorLen(self: *Self, io: std.Io) errors.DescriptorError!u32 {
            var size: u32 = 0;
            _ = try self.call(io, "HIDIOCGRDESCSIZE", requests.GRDESCSIZE, &size);
            return size;
        }

        /// Copy the device's HID report descriptor into `buf`.
        pub fn getReportDescriptor(
            self: *Self,
            io: std.Io,
            buf: []u8,
        ) errors.DescriptorError![]const u8 {
            const size = try self.getReportDescriptorLen(io);
            if (buf.len < size) return error.BufferTooSmall;
            var rd: ReportDescriptor = .init(size);
            _ = try self.call(io, "HIDIOCGRDESC", requests.GRDESC, &rd);
            @memcpy(buf[0..size], rd.value[0..size]);
            return buf[0..size];
        }

        /// Fill in everything the open device itself can answer.
        ///
        /// Less than enumeration answers, because this asks the HID device
        /// rather than the system: the manufacturer, product and serial
        /// strings belong to the USB device the HID function sits on, and the
        /// HID device reports only the first two run together. `manufacturer`
        /// is therefore left unreported here and `product` carries the
        /// combined name.
        pub fn getInfo(
            self: *Self,
            io: std.Io,
            out: *DeviceInfo,
        ) (errors.DeviceError || std.Io.Cancelable)!void {
            out.* = .empty;

            var raw: DevInfo = .zero;
            _ = try self.call(io, "HIDIOCGRAWINFO", requests.GRAWINFO, &raw);
            out.vendor_id = raw.vendor;
            out.product_id = raw.product;
            out.native_bus = @truncate(raw.bustype);
            out.bus_type = busType(out.native_bus);

            var buf: [Str.max_len]u8 = undefined;
            out.product = try self.string(io, "HIDIOCGRAWNAME", requests.GRAWNAME, &buf);
            out.serial_number = try self.string(io, "HIDIOCGRAWUNIQ", requests.GRAWUNIQ, &buf);
            out.physical_location = try self.string(io, "HIDIOCGRAWPHYS", requests.GRAWPHYS, &buf);
        }

        /// Send a feature report over the control endpoint as a Set_Report
        /// transfer.
        pub fn sendFeatureReport(
            self: *Self,
            io: std.Io,
            data: []const u8,
        ) errors.ReportError!usize {
            if (data.len > requests.max_len) return error.ReportTooLarge;
            return self.call(
                io,
                "HIDIOCSFEATURE",
                requests.SFEATURE(@intCast(data.len)),
                @constCast(data.ptr),
            );
        }

        /// Request a feature report over the control endpoint.
        pub fn getFeatureReport(self: *Self, io: std.Io, buf: []u8) errors.ReportError![]u8 {
            if (buf.len > requests.max_len) return error.ReportTooLarge;
            const got = try self.call(
                io,
                "HIDIOCGFEATURE",
                requests.GFEATURE(@intCast(buf.len)),
                buf.ptr,
            );
            return buf[0..got];
        }

        /// Request an input report over the control endpoint, rather than
        /// waiting for one on the interrupt IN endpoint as `read` does.
        pub fn getInputReport(self: *Self, io: std.Io, buf: []u8) errors.ReportError![]u8 {
            if (buf.len > requests.max_len) return error.ReportTooLarge;
            const got = try self.call(
                io,
                "HIDIOCGINPUT",
                requests.GINPUT(@intCast(buf.len)),
                buf.ptr,
            );
            return buf[0..got];
        }

        /// Always zero: `hidraw` queues input reports in the kernel -- 64 of
        /// them on both systems -- so this library never has to drop one.
        pub fn takeDroppedReports(self: *Self) u64 {
            _ = self;
            return 0;
        }

        /// Map what `file_read_streaming` answers onto the portable read
        /// errors.
        ///
        /// `EndOfStream` is the interesting one. A `hidraw` descriptor whose
        /// device has been unplugged reads zero bytes rather than failing,
        /// which is how a read loop finds out the device is gone -- and it has
        /// to be told apart from a legitimately empty report, which a device
        /// may also send, and which is why `readTimeout` answers with an
        /// optional rather than a zero-length slice.
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
    };
}

test "the bus table maps the values both kernels share" {
    try std.testing.expectEqual(BusType.usb, busType(0x03));
    try std.testing.expectEqual(BusType.bluetooth, busType(0x05));
    try std.testing.expectEqual(BusType.virtual, busType(0x06));
    try std.testing.expectEqual(BusType.i2c, busType(0x18));
    try std.testing.expectEqual(BusType.spi, busType(0x1C));
    try std.testing.expectEqual(BusType.unknown, busType(0x00));
    // BUS_I8042, which is real and has no portable spelling.
    try std.testing.expectEqual(BusType.other, busType(0x11));
}

test {
    std.testing.refAllDecls(@This());
}
