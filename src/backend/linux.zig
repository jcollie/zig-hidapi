// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Linux backend: `/dev/hidraw*` driven by the `HIDIOC*` ioctls of
//! `uapi/linux/hidraw.h`.
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

/// An open `hidraw` file descriptor.
pub const Handle = linux.fd_t;

/// The minor number of a `hidraw` node, i.e. the `N` in `/dev/hidrawN`.
pub const Minor = linux.dev_t;

/// The bus a device is attached to, as the `BUS_*` values of
/// `uapi/linux/input.h`.
pub const BUS = ioctl.BUS;

/// Bus type, vendor ID and product ID as one `HIDIOCGRAWINFO` answers them.
pub const DevInfo = ioctl.hidraw_devinfo;

/// The largest report descriptor the kernel will hand out, so a buffer this
/// size always fits one.
pub const max_report_descriptor_len = ioctl.HID_MAX_DESCRIPTOR_SIZE;

/// Open `/dev/hidraw{minor}` for reading and writing.
///
/// Fails with `error.HIDDeviceDoesNotExist` when there is no such node and
/// `error.HIDDeviceNoAccess` when the caller lacks permission to open it.
pub fn open(io: std.Io, minor: Minor) !Handle {
    var p = try io.concurrent(_open, .{minor});
    defer _ = p.cancel(io) catch {};
    return try p.await(io);
}

fn _open(minor: Minor) !Handle {
    var buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/dev/hidraw{d}", .{minor});

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
        .SUCCESS => @as(Handle, @intCast(rc)),
        .ACCES => error.HIDDeviceNoAccess,
        .NOENT => error.HIDDeviceDoesNotExist,
        else => error.HIDDeviceUnknownOpenError,
    };
}

/// Close the device. Errors are not reported.
pub fn close(io: std.Io, handle: Handle) void {
    var p = io.concurrent(_close, .{handle}) catch return;
    defer p.cancel(io);
    p.await(io);
}

fn _close(handle: Handle) void {
    _ = linux.close(handle);
}

/// Read an input report from the interrupt IN endpoint.
///
/// The device is opened in blocking mode, so this waits until the device sends
/// a report.
pub fn read(io: std.Io, handle: Handle, buf: []u8) ![]const u8 {
    var p = try io.concurrent(_read, .{ handle, buf });
    defer _ = p.cancel(io) catch {};
    return p.await(io);
}

fn _read(handle: Handle, buf: []u8) ![]const u8 {
    const rc = linux.read(handle, buf.ptr, buf.len);
    switch (linux.errno(rc)) {
        .SUCCESS => return buf[0..rc],
        else => |e| {
            log.warn("read: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Write an output report to the first OUT endpoint, or to the control
/// endpoint when the device has none.
pub fn write(io: std.Io, handle: Handle, data: []const u8) !usize {
    var p = try io.concurrent(_write, .{ handle, data });
    defer _ = p.cancel(io) catch {};
    return try p.await(io);
}

fn _write(handle: Handle, data: []const u8) !usize {
    const rc = linux.write(handle, data.ptr, data.len);
    switch (linux.errno(rc)) {
        .SUCCESS => return rc,
        else => |e| {
            log.warn("write: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Issue `request` on `handle` with `arg`, reporting a failing syscall as
/// `error.HIDError` after logging its `errno`.
///
/// Every ioctl below goes through this, which is what keeps the log line and
/// the error identical across all of them.
fn call(io: std.Io, handle: Handle, what: []const u8, request: u32, arg: usize) !usize {
    switch (try ioctl.ioctl(io, handle, request, arg)) {
        .success => |rc| return rc,
        .failure => |e| {
            log.warn("{s}: {s}", .{ what, @tagName(e) });
            return error.HIDError;
        },
    }
}

/// The shared body of `getRawName`, `getRawUniq` and `getPhysicalLocation`.
///
/// All three ioctls behave the same way: they copy a NUL terminated string
/// into the caller's buffer, clamped to its length, and return the number of
/// bytes copied including the terminator.
///
/// Returns `error.BufferTooLarge` if `buf` is longer than a request number can
/// name, which no useful buffer is; see `ioctl.Size`.
fn string(
    io: std.Io,
    handle: Handle,
    what: []const u8,
    comptime request: fn (len: ioctl.Size) u32,
    buf: []u8,
) !?[:0]const u8 {
    const request_len = std.math.cast(ioctl.Size, buf.len) orelse
        return error.BufferTooLarge;
    const len = try call(io, handle, what, request(request_len), @intFromPtr(buf.ptr));

    // A zero length means `buf` was empty, and a lone terminator means the
    // string was. A single byte that is not the terminator is a string the
    // buffer could not hold, which the check below catches.
    if (len == 0 or (len == 1 and buf[0] == 0)) return null;
    // The ioctl clamps its copy to `buf.len` and does not terminate a string
    // it had to truncate, so a missing terminator means it did not fit.
    if (buf[len - 1] != 0) return error.BufferTooSmall;
    return buf[0 .. len - 1 :0];
}

/// Get the size in bytes of the device's HID report descriptor.
pub fn getReportDescriptorSize(io: std.Io, handle: Handle) !u32 {
    var size: u32 = 0;
    _ = try call(io, handle, "HIDIOCGRDESCSIZE", ioctl.HIDIOCGRDESCSIZE, @intFromPtr(&size));
    return size;
}

/// Copy the device's HID report descriptor into `buf`.
///
/// Returns `error.BufferTooSmall` if `buf` is shorter than the descriptor.
pub fn getReportDescriptor(io: std.Io, handle: Handle, buf: []u8) ![]const u8 {
    const size = try getReportDescriptorSize(io, handle);
    if (buf.len < size) return error.BufferTooSmall;
    // `hidraw_report_descriptor` carries the whole 4 KiB buffer by value
    // rather than a pointer, so this is worth keeping off a small stack.
    var descriptor: ioctl.hidraw_report_descriptor = .init(size);
    _ = try call(io, handle, "HIDIOCGRDESC", ioctl.HIDIOCGRDESC, @intFromPtr(&descriptor));
    @memcpy(buf[0..size], descriptor.value[0..size]);
    return buf[0..size];
}

/// Get the device's vendor and product strings, UTF-8 encoded, or `null` when
/// it reports no name at all.
pub fn getRawName(io: std.Io, handle: Handle, buf: []u8) !?[:0]const u8 {
    return string(io, handle, "HIDIOCGRAWNAME", ioctl.HIDIOCGRAWNAME, buf);
}

/// Get the device's `uniq` string -- the USB serial number or the Bluetooth
/// hardware address -- or `null` when it reports none, which is the common
/// case for USB.
pub fn getRawUniq(io: std.Io, handle: Handle, buf: []u8) !?[:0]const u8 {
    return string(io, handle, "HIDIOCGRAWUNIQ", ioctl.HIDIOCGRAWUNIQ, buf);
}

/// Get the physical address of the device: the path through the controller,
/// hubs and ports for USB, and the hardware address for Bluetooth.
pub fn getPhysicalLocation(io: std.Io, handle: Handle, buf: []u8) !?[:0]const u8 {
    return string(io, handle, "HIDIOCGRAWPHYS", ioctl.HIDIOCGRAWPHYS, buf);
}

/// Get the device's bus type, vendor ID and product ID in a single ioctl.
pub fn getDeviceInfo(io: std.Io, handle: Handle) !DevInfo {
    var info: DevInfo = .init;
    _ = try call(io, handle, "HIDIOCGRAWINFO", ioctl.HIDIOCGRAWINFO, @intFromPtr(&info));
    return info;
}

/// Send a feature report over the control endpoint as a Set_Report transfer.
///
/// The first byte of `data` is the report ID, `0x00` for a device that does
/// not use numbered reports.
pub fn sendFeatureReport(io: std.Io, handle: Handle, data: []const u8) !usize {
    const request_len = std.math.cast(ioctl.Size, data.len) orelse
        return error.BufferTooLarge;
    return call(
        io,
        handle,
        "HIDIOCSFEATURE",
        ioctl.HIDIOCSFEATURE(request_len),
        @intFromPtr(data.ptr),
    );
}

/// Request a feature report over the control endpoint.
///
/// Set the first byte of `buf` to the report ID wanted; it is still there on
/// return, with the report data from `buf[1]`.
pub fn getFeatureReport(io: std.Io, handle: Handle, buf: []u8) ![]const u8 {
    const request_len = std.math.cast(ioctl.Size, buf.len) orelse
        return error.BufferTooLarge;
    const len = try call(
        io,
        handle,
        "HIDIOCGFEATURE",
        ioctl.HIDIOCGFEATURE(request_len),
        @intFromPtr(buf.ptr),
    );
    return buf[0..len];
}

/// Request an input report over the control endpoint, rather than waiting for
/// one on the interrupt IN endpoint as `read` does.
pub fn getInputReport(io: std.Io, handle: Handle, buf: []u8) ![]const u8 {
    const request_len = std.math.cast(ioctl.Size, buf.len) orelse
        return error.BufferTooLarge;
    const len = try call(
        io,
        handle,
        "HIDIOCGINPUT",
        ioctl.HIDIOCGINPUT(request_len),
        @intFromPtr(buf.ptr),
    );
    return buf[0..len];
}

test {
    // Not recursive, so this reaches the declarations above but not the
    // private helpers they call; those are analyzed because these call them.
    std.testing.refAllDecls(@This());
}
