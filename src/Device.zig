// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const Device = @This();

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.hidapi_device);

const ioctl = @import("ioctl.zig");
const DeviceInfo = @import("DeviceInfo.zig");

minor: linux.dev_t,
fd: linux.fd_t,

pub fn open(io: std.Io, minor: linux.dev_t) !Device {
    return .{
        .minor = minor,
        .fd = fd: {
            var p = try io.concurrent(_open, .{minor});
            defer _ = p.cancel(io) catch {};
            break :fd try p.await(io);
        },
    };
}

fn _open(minor: linux.dev_t) !linux.fd_t {
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
        .SUCCESS => @as(linux.fd_t, @intCast(rc)),
        .ACCES => return error.HIDDeviceNoAccess,
        .NOENT => return error.HIDDeviceDoesNotExist,
        else => {
            return error.HIDDeviceUnknownOpenError;
        },
    };
}

pub fn close(self: Device, io: std.Io) void {
    var p = io.concurrent(_close, .{self.fd}) catch return;
    defer p.cancel(io);
    p.await(io);
}

fn _close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

pub fn getReportDescriptorSize(self: Device, io: std.Io) !u32 {
    var report_descriptor_size: u32 = 0;
    const rc = try ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGRDESCSIZE,
        @intFromPtr(&report_descriptor_size),
    );
    switch (rc) {
        .success => {
            return report_descriptor_size;
        },
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getReportDescriptor(self: Device, io: std.Io, buf: []u8) ![]const u8 {
    const size = try self.getReportDescriptorSize();
    if (buf.len < size) return error.BufferTooSmall;
    var report_descriptor: ioctl.hidraw_report_descriptor = .init(size);
    const rc = try ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGRDESC,
        @intFromPtr(&report_descriptor),
    );
    switch (rc) {
        .success => {
            @memcpy(buf[0..size], report_descriptor.value[0..size]);
            return buf[0..size];
        },
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getRawName(self: Device, io: std.Io, buf: []u8) ![]const u8 {
    const rc = try ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGRAWNAME(buf.len),
        @intFromPtr(buf.ptr),
    );
    switch (rc) {
        .success => |len| return buf[0..len],
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getPhysicalLocation(self: Device, io: std.Io, buf: []u8) ![]const u8 {
    const rc = try ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGRAWPHYS(buf.len),
        @intFromPtr(buf.ptr),
    );
    switch (rc) {
        .success => |len| return buf[0..len],
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getDeviceInfo(self: Device, io: std.Io) !DeviceInfo {
    var info = std.mem.zeroes(ioctl.hidraw_devinfo);
    const rc = try ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGRAWINFO,
        @intFromPtr(&info),
    );
    switch (rc) {
        .success => {
            return DeviceInfo.init(self.minor, &info);
        },
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getBusType(self: Device, io: std.Io) !ioctl.BUS {
    var info: ioctl.hidraw_devinfo = .init;
    const rc = ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGRAWINFO,
        @intFromPtr(&info),
    );
    switch (rc) {
        .success => return info.bustype,
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getVendorID(self: Device, io: std.Io) !u16 {
    var info: ioctl.hidraw_devinfo = .init;
    const rc = ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGRAWINFO,
        @intFromPtr(&info),
    );
    switch (rc) {
        .success => return info.vendor,
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getProductID(self: Device, io: std.Io) !u16 {
    var info: ioctl.hidraw_devinfo = .init;
    const rc = ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGRAWINFO,
        @intFromPtr(&info),
    );
    switch (rc) {
        .success => {
            return info.vendor;
        },
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Send a Feature report to the device.
///
/// Feature reports are sent over the Control endpoint as a Set_Report transfer.
/// The first byte of `data` must contain the Report ID. For devices which
/// only support a single report, this must be set to 0x0. The remaining
/// bytes contain the report data. Since the Report ID is mandatory, calls
/// to sendFeatureReport() will always contain one more byte than the report
/// contains. For example, if a hid report is 16 bytes long, 17 bytes must be
/// passed to sendFeatureReport(): the Report ID (or 0x0, for devices which do
/// not use numbered reports), followed by the report data (16 bytes). In this
/// example, the length passed in would be 17.
pub fn sendFeatureReport(self: Device, io: std.Io, data: []const u8) !usize {
    const rc = ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCSFEATURE(data.len),
        @intFromPtr(data.ptr),
    );
    switch (rc) {
        .success => {
            return rc;
        },
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Get a feature report from a HID device.
///
/// Set the first byte of `buf` to the Report ID of the report to be read. Make
/// sure to allow space for this extra byte in `buf`. Upon return, the first
/// byte will still contain the Report ID, and the report data will start in
/// buf[1].
pub fn getFeatureReport(self: Device, io: std.Io, buf: []u8) ![]const u8 {
    const rc = ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGFEATURE(buf.len),
        @intFromPtr(buf.ptr),
    );
    switch (rc) {
        .success => |len| return buf[0..len],
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Get a input report from a HID device.
///
/// Set the first byte of `buf` to the report ID of the report to be read. Make
/// sure to allow space for this extra byte in `buf`. Upon return, the first
/// byte will still contain the report ID, and the report data will start in
/// `buf[1]`.
pub fn getInputReport(self: Device, io: std.Io, buf: []u8) ![]const u8 {
    const rc = ioctl.ioctl(
        io,
        self.fd,
        ioctl.HIDIOCGINPUT(buf.len),
        @intFromPtr(buf.ptr),
    );
    switch (rc) {
        .success => |len| return buf[0..len],
        .failure => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Write an output report to a HID device.
///
/// The first byte of `buf` must contain the report ID. For devices which
/// only support a single report, this must be set to 0x0. The remaining
/// bytes contain the report data. Since the report ID is mandatory, calls
/// to `write()` will always contain one more byte than the report contains.
/// For example, if a HID report is 16 bytes long, 17 bytes must be passed
/// to `write()`, the report ID (or 0x0, for devices with a single report),
/// followed by the report data (16 bytes).
///
/// write() will send the data on the first OUT endpoint, if one exists. If it
/// does not, it will send the data through the Control Endpoint (Endpoint 0).
pub fn write(self: Device, io: std.Io, buf: []const u8) !usize {
    var p = try io.concurrent(_write, .{ self.fd, buf });
    defer _ = p.cancel(io) catch {};
    return try p.await(io);
}

fn _write(fd: linux.fd_t, data: []const u8) !usize {
    const rc = linux.write(fd, data.ptr, data.len);
    switch (linux.errno(rc)) {
        .SUCCESS => return rc,
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Read an input report from a HID device.
///
/// Input reports are returned to the host through the INTERRUPT IN endpoint.
/// The first byte will contain the report number if the device uses numbered
/// reports.
pub fn read(self: Device, io: std.Io, data: []u8) ![]const u8 {
    var p = try io.concurrent(_read, .{ self.fd, data });
    defer _ = p.cancel(io) catch {};
    return p.await(io);
}

fn _read(fd: linux.fd_t, data: []u8) ![]const u8 {
    const rc = linux.read(fd, data.ptr, data.len);
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return data[0..rc];
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}
