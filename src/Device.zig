const Device = @This();

const std = @import("std");
const log = std.log.scoped(.hidapi);

const ioctl = @import("ioctl.zig");
const DeviceInfo = @import("DeviceInfo.zig");

fd: std.os.linux.fd_t,

pub fn open(path: []const u8) !Device {
    return .{
        .fd = fd: {
            const rc = std.os.linux.open(
                path,
                .{
                    .ACCMODE = .RDWR,
                    .APPEND = true,
                    .NONBLOCK = true,
                },
                0,
            );
            break :fd switch (std.os.linux.E.init(rc)) {
                .SUCCESS => @as(std.os.linux.fd_t, @intCast(rc)),
                else => |e| {
                    log.err("problem: {s} {s}", .{ path, @tagName(e) });
                    return error.OpenError;
                },
            };
        },
    };
}

pub fn close(self: Device) void {
    _ = std.os.linux.close(self.fd);
}

pub fn getVendorID(self: Device) !u16 {
    var info = std.mem.zeroes(ioctl.hidraw_devinfo);
    const rc = std.os.linux.ioctl(self.fd, ioctl.HIDIOCGRAWINFO, @intFromPtr(&info));
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {
            return info.vendor;
        },
        else => |e| {
            log.err("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

pub fn getProductID(self: Device) !c_ushort {
    var info = std.mem.zeroes(ioctl.hidraw_devinfo);
    const rc = std.os.linux.ioctl(self.fd, ioctl.HIDIOCGRAWINFO, @intFromPtr(&info));
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {
            return info.vendor;
        },
        else => |e| {
            log.err("problem: {s}", .{@tagName(e)});
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
    const rc = std.os.linux.ioctl(self.fd, ioctl.HIDIOCSFEATURE(data.len), @intFromPtr(data.ptr));
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {
            log.info("{} {any}", .{ rc, data[0..rc] });
            return rc;
        },
        else => |e| {
            log.err("problem: {s}", .{@tagName(e)});
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
    const rc = std.os.linux.ioctl(self.fd, ioctl.HIDIOCGFEATURE(data.len), @intFromPtr(data.ptr));
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {
            log.info("{} {any}", .{ rc, data[0..rc] });
            return rc;
        },
        else => |e| {
            log.err("problem: {s}", .{@tagName(e)});
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
    const rc = std.os.linux.ioctl(self.fd, ioctl.HIDIOCGINPUT(data.len), @intFromPtr(data.ptr));
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {
            log.info("{} {any}", .{ rc, data[0..rc] });
            return rc;
        },
        else => |e| {
            log.err("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

/// Set the device handle to be non-blocking.
///
/// In non-blocking mode calls to read() will return immediately with a
/// null if there is no data to be read. In blocking mode, read() will
/// wait (block) until there is data to read before returning.
///
/// Nonblocking can be turned on and off at any time.
// pub fn setNonblocking(self: @This(), nonblocking: bool) !void {
// const result = hidapi.c.hid_set_nonblocking(self.device, if (nonblocking) 1 else 0);
// if (result < 0) return error.HIDApiError;
// }

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
    const rc = std.os.linux.write(self.fd, data.ptr, data.len);
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {
            return rc;
        },
        else => |e| {
            log.err("problem: {s}", .{@tagName(e)});
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
    const rc = std.os.linux.write(self.fd, data.ptr, data.len);
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {
            return data[0..rc];
        },
        else => |e| {
            log.err("problem: {s}", .{@tagName(e)});
            return error.HIDError;
        },
    }
}

// Get The Manufacturer String from a HID device.
// pub fn getManufacturerString(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
//     var buffer: [128]hidapi.c.wchar_t = undefined;
//     const result = hidapi.c.hid_get_manufacturer_string(self.device, &buffer, buffer.len);
//     if (result < 0) return error.HIDApiError;
//     return (try hidapi.fromWCharAlloc(alloc, &buffer)) orelse return error.HIDApiError;
// }

// Get The Product String from a HID device.
// pub fn getProductString(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
//     var buffer: [128]hidapi.c.wchar_t = undefined;
//     const result = hidapi.c.hid_get_product_string(self.device, &buffer, buffer.len);
//     if (result < 0) return error.HIDApiError;
//     return (try hidapi.fromWCharAlloc(alloc, &buffer)) orelse return error.HIDApiError;
// }

// Get The Serial Number String from a HID device.
// pub fn getSerialNumberString(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
//     var buffer: [128]hidapi.c.wchar_t = undefined;
//     const result = hidapi.c.hid_get_serial_number_string(self.device, &buffer, buffer.len);
//     if (result < 0) return error.HIDApiError;
//     return try hidapi.fromWCharAlloc(alloc, &buffer);
// }

// Get a string from a HID device, based on its string index.
// pub fn getIndexedString(self: @This(), alloc: std.mem.Allocator, string_index: c_int) ![]const u8 {
//     var buffer: [128]hidapi.c.wchar_t = undefined;
//     const result = hidapi.c.hid_get_indexed_string(self.device, string_index, &buffer, buffer.len);
//     if (result < 0) return error.HIDApiError;
//     return try hidapi.fromWCharAlloc(alloc, &buffer);
// }

// Get a report descriptor from a HID device.
// pub fn getReportDescriptor(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
//     var buffer: [hidapi.MAX_REPORT_DESCRIPTOR_SIZE]u8 = undefined;
//     const result = hidapi.c.hid_get_report_descriptor(self.device, &buffer, buffer.len);
//     if (result < 0) return error.HIDApiError;
//     return try alloc.dupe(u8, buffer[0..@intCast(result)]);
// }

// pub fn getDeviceInfo(self: @This(), alloc: std.mem.Allocator) !DeviceInfo {
//     if (hidapi.c.hid_get_device_info(self.device)) |hid_device_info| {
//         return DeviceInfo.init(alloc, hid_device_info);
//     }
//     return error.HIDApiError;
// }
