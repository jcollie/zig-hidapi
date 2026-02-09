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

pub fn open(minor: linux.dev_t) !Device {
    return .{
        .minor = minor,
        .fd = fd: {
            var buf: [std.fs.max_name_bytes]u8 = undefined;
            const path = try std.fmt.bufPrintZ(&buf, "/dev/hidraw{d}", .{minor});

            const rc = linux.open(
                path,
                .{
                    .ACCMODE = .RDWR,
                    .APPEND = true,
                    .NONBLOCK = true,
                },
                0,
            );
            break :fd switch (linux.errno(rc)) {
                .SUCCESS => @as(linux.fd_t, @intCast(rc)),
                .ACCES => return error.HIDDeviceNoAccess,
                .NOENT => return error.HIDDeviceDoesNotExist,
                else => {
                    return error.HIDDeviceUnknownOpenError;
                },
            };
        },
    };
}

pub fn close(self: Device) void {
    _ = linux.close(self.fd);
}

pub fn getReportDescriptorSize(self: Device) !u32 {
    var report_descriptor_size: u32 = 0;
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGRDESCSIZE, @intFromPtr(&report_descriptor_size));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return report_descriptor_size;
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getReportDescriptor(self: Device) !void {
    const size = try self.getReportDescriptorSize();
    var report_descriptor: ioctl.hidraw_report_descriptor = .init(size);
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGRDESC, @intFromPtr(&report_descriptor));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return;
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getRawName(self: Device, buf: []u8) ![]const u8 {
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGRAWNAME(buf.len), @intFromPtr(buf.ptr));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return std.mem.span(buf);
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getPhysicalLocation(self: Device, buf: []u8) ![]const u8 {
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGRAWPHYS(buf.len), @intFromPtr(buf.ptr));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return std.mem.span(buf);
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getDeviceInfo(self: Device) !DeviceInfo {
    var info = std.mem.zeroes(ioctl.hidraw_devinfo);
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGRAWINFO, @intFromPtr(&info));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return DeviceInfo.init(self.minor, &info);
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getBusType(self: Device) !ioctl.BUS {
    var info = std.mem.zeroes(ioctl.hidraw_devinfo);
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGRAWINFO, @intFromPtr(&info));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return info.bustype;
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getVendorID(self: Device) !u16 {
    var info = std.mem.zeroes(ioctl.hidraw_devinfo);
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGRAWINFO, @intFromPtr(&info));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return info.vendor;
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getProductID(self: Device) !u16 {
    var info = std.mem.zeroes(ioctl.hidraw_devinfo);
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGRAWINFO, @intFromPtr(&info));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return info.vendor;
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Send a Feature report to the device.
///
/// Feature reports are sent over the Control endpoint as a Set_Report
/// transfer.  The first byte of `data` must contain the Report ID. For
/// devices which only support a single report, this must be set to 0x0.
/// The remaining bytes contain the report data. Since the Report ID is
/// mandatory, calls to sendFeatureReport() will always contain one more
/// byte than the report contains. For example, if a hid report is 16 bytes
/// long, 17 bytes must be passed to hid_send_feature_report(): the Report
/// ID (or 0x0, for devices which do not use numbered reports), followed by
/// the report data (16 bytes). In this example, the length passed in would
/// be 17.
pub fn sendFeatureReport(self: Device, data: []const u8) !usize {
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCSFEATURE(data.len), @intFromPtr(data.ptr));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return rc;
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Get a feature report from a HID device.
///
/// Set the first byte of `data` to the Report ID of the report to be read.
/// Make sure to allow space for this extra byte in `data`. Upon return, the
/// first byte will still contain the Report ID, and the report data will
/// start in data[1].
pub fn getFeatureReport(self: Device, data: []u8) ![]const u8 {
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGFEATURE(data.len), @intFromPtr(data.ptr));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            log.info("{} {any}", .{ rc, data[0..rc] });
            return data[0..rc];
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Get a input report from a HID device.
///
/// Set the first byte of `data` to the Report ID of the report to be read.
/// Make sure to allow space for this extra byte in `data`. Upon return, the
/// first byte will still contain the Report ID, and the report data will
/// start in `data[1]`.
pub fn getInputReport(self: Device, data: []u8) ![]const u8 {
    const rc = linux.ioctl(self.fd, ioctl.HIDIOCGINPUT(data.len), @intFromPtr(data.ptr));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            log.info("{} {any}", .{ rc, data[0..rc] });
            return rc;
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Write an Output report to a HID device.
///
/// The first byte of `data` must contain the Report ID. For
/// devices which only support a single report, this must be set
/// to 0x0. The remaining bytes contain the report data. Since
/// the Report ID is mandatory, calls to `write()` will always
/// contain one more byte than the report contains. For example,
/// if a HID report is 16 bytes long, 17 bytes must be passed to
/// `write()`, the Report ID (or 0x0, for devices with a
/// single report), followed by the report data (16 bytes).
///
/// write() will send the data on the first OUT endpoint, if
/// one exists. If it does not, it will send the data through
/// the Control Endpoint (Endpoint 0).
pub fn write(self: Device, data: []const u8) !usize {
    const rc = linux.write(self.fd, data.ptr, data.len);
    switch (linux.errno(rc)) {
        .SUCCESS => {
            return rc;
        },
        else => |e| {
            log.warn("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Read an Input report from a HID device.
///
/// Input reports are returned to the host through the INTERRUPT IN endpoint.
/// The first byte will contain the Report number if the device uses numbered
/// reports.
pub fn read(self: Device, data: []u8) ![]const u8 {
    const rc = linux.read(self.fd, data.ptr, data.len);
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
