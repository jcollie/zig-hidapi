// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! An open HID device, and every operation on one.
//!
//! This is the portable half: it holds the conventions that are the same
//! everywhere -- the report ID in the first byte, what an empty answer means,
//! which errors callers see -- and forwards the system calls to the backend
//! for the operating system being built for. `src/backend.zig` picks that
//! backend and `src/backend/contract.zig` says what it has to provide.
//!
//! Every method takes a `std.Io` and dispatches its syscall through it rather
//! than issuing it directly, which leaves the choice of how to wait up to the
//! caller's `Io` implementation. The call itself still completes before the
//! method returns; see `read` for the one that can wait indefinitely.
//!
//! Methods that wrap an ioctl report any failure as `error.HIDError`, logging
//! the underlying `errno` at warning level.

const Device = @This();

const std = @import("std");

const backend = @import("backend.zig");
const impl = backend.impl;
const DeviceInfo = @import("DeviceInfo.zig");

/// The minor number of the `hidraw` node, i.e. the `N` in `/dev/hidrawN`.
minor: impl.Minor,
/// Handle for the open device.
fd: impl.Handle,

/// Open `/dev/hidraw{minor}` for reading and writing.
///
/// The caller owns the returned device and must `close` it.
///
/// Fails with `error.HIDDeviceDoesNotExist` when there is no such node and
/// `error.HIDDeviceNoAccess` when the caller lacks permission to open it,
/// which is the common case for an unprivileged process; see the udev rule
/// in the README.
pub fn open(io: std.Io, minor: impl.Minor) !Device {
    return .{
        .minor = minor,
        .fd = try impl.open(io, minor),
    };
}

/// Close the device. Errors are not reported.
pub fn close(self: Device, io: std.Io) void {
    impl.close(io, self.fd);
}

/// Get the size in bytes of the device's HID report descriptor.
///
/// Never exceeds `max_report_descriptor_size`.
pub fn getReportDescriptorSize(self: Device, io: std.Io) !u32 {
    return impl.getReportDescriptorSize(io, self.fd);
}

/// The largest report descriptor any device will report, so a buffer this
/// size always holds one.
pub const max_report_descriptor_size = impl.max_report_descriptor_len;

/// Copy the device's HID report descriptor into `buf` and return the
/// portion written.
///
/// Returns `error.BufferTooSmall` if `buf` is shorter than the descriptor;
/// size it with `getReportDescriptorSize`, or use
/// `max_report_descriptor_size` to be sure it always fits.
pub fn getReportDescriptor(self: Device, io: std.Io, buf: []u8) ![]const u8 {
    return impl.getReportDescriptor(io, self.fd, buf);
}

/// Get the device's vendor and product strings, UTF-8 encoded.
///
/// Returns `null` when the device reports no name at all. Otherwise the
/// result aliases `buf` and is NUL terminated.
///
/// Returns `error.BufferTooSmall` if `buf` cannot hold the name and its
/// terminator. 256 bytes is enough for any name the kernel will report.
pub fn getRawName(self: Device, io: std.Io, buf: []u8) !?[:0]const u8 {
    return impl.getRawName(io, self.fd, buf);
}

/// Get the device's `uniq` string, an identifier meant to be unique to the
/// individual device: usbhid seeds it from the USB serial number string and
/// the Bluetooth transports from the hardware (MAC) address, though a device
/// driver may replace it with a serial of its own.
///
/// Returns `null` when the device reports no `uniq`, which is the common
/// case for USB devices. Otherwise the result aliases `buf` and is NUL
/// terminated.
///
/// Returns `error.BufferTooSmall` if `buf` cannot hold the string and its
/// terminator. The kernel keeps `uniq` in a 64 byte field, so a 64 byte
/// buffer always fits.
pub fn getRawUniq(self: Device, io: std.Io, buf: []u8) !?[:0]const u8 {
    return impl.getRawUniq(io, self.fd, buf);
}

/// Get a string describing the physical address of the device.
///
/// For USB devices this is the physical path through the controller, hubs
/// and ports; for Bluetooth devices it is the hardware (MAC) address.
///
/// Returns `null` when the device reports no location. Otherwise the result
/// aliases `buf` and is NUL terminated.
pub fn getPhysicalLocation(self: Device, io: std.Io, buf: []u8) !?[:0]const u8 {
    return impl.getPhysicalLocation(io, self.fd, buf);
}

/// Get the device's bus type, vendor ID and product ID in a single call.
///
/// The returned `DeviceInfo` carries this device, which the caller still
/// owns. Prefer this over calling `getBusType`, `getVendorID` and
/// `getProductID` separately, since each of those repeats the same work.
pub fn getDeviceInfo(self: Device, io: std.Io) !DeviceInfo {
    const info = try impl.getDeviceInfo(io, self.fd);
    return .init(self, &info);
}

/// Get the bus the device is attached to.
///
/// `BUS` is non-exhaustive, because the system may report a bus this library
/// does not name yet.
pub fn getBusType(self: Device, io: std.Io) !impl.BUS {
    return (try impl.getDeviceInfo(io, self.fd)).bustype;
}

/// Get the device's vendor ID (VID).
pub fn getVendorID(self: Device, io: std.Io) !u16 {
    return (try impl.getDeviceInfo(io, self.fd)).vendor;
}

/// Get the device's product ID (PID).
pub fn getProductID(self: Device, io: std.Io) !u16 {
    return (try impl.getDeviceInfo(io, self.fd)).product;
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
    return impl.sendFeatureReport(io, self.fd, data);
}

/// Get a feature report from a HID device.
///
/// Set the first byte of `buf` to the Report ID of the report to be read. Make
/// sure to allow space for this extra byte in `buf`. Upon return, the first
/// byte will still contain the Report ID, and the report data will start in
/// buf[1].
pub fn getFeatureReport(self: Device, io: std.Io, buf: []u8) ![]const u8 {
    return impl.getFeatureReport(io, self.fd, buf);
}

/// Get an input report from a HID device.
///
/// Set the first byte of `buf` to the report ID of the report to be read. Make
/// sure to allow space for this extra byte in `buf`. Upon return, the first
/// byte will still contain the report ID, and the report data will start in
/// `buf[1]`.
pub fn getInputReport(self: Device, io: std.Io, buf: []u8) ![]const u8 {
    return impl.getInputReport(io, self.fd, buf);
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
    return impl.write(io, self.fd, buf);
}

/// Read an input report from a HID device.
///
/// Input reports are returned to the host through the INTERRUPT IN endpoint.
/// The first byte will contain the report number if the device uses numbered
/// reports.
///
/// The device is opened in blocking mode, so this waits until the device sends
/// a report. A device that is simply idle, such as a mouse nobody is touching,
/// will not return from this call.
pub fn read(self: Device, io: std.Io, data: []u8) ![]const u8 {
    return impl.read(io, self.fd, data);
}

test {
    // `std.testing.refAllDecls` is not recursive, so the root module
    // referencing this file does not reach these functions. Referencing them
    // here is what makes the semantic analyzer check every method body, which
    // catches errors in methods that no test happens to call.
    std.testing.refAllDecls(@This());
}

test "read-only ioctls against attached devices" {
    const io = std.testing.io;

    var buf: [256]u8 = undefined;
    var descriptor: [max_report_descriptor_size]u8 = undefined;
    var checked: usize = 0;

    for (0..64) |minor| {
        const device = open(io, @intCast(minor)) catch continue;
        defer device.close(io);

        // Only side-effect-free calls belong here, because this runs against
        // whatever hardware happens to be attached. `read` blocks until the
        // device sends a report, and `write` and `sendFeatureReport` change
        // device state, so all three are covered by the reference above only.
        const info = try device.getDeviceInfo(io);
        try std.testing.expectEqual(info.bustype, try device.getBusType(io));
        try std.testing.expectEqual(info.vendor, try device.getVendorID(io));
        try std.testing.expectEqual(info.product, try device.getProductID(io));

        _ = try device.getPhysicalLocation(io, &buf);

        // A buffer that cannot hold the name and its terminator has to be
        // reported. The ioctl truncates without terminating, so getting this
        // wrong trips the sentinel check on the returned slice instead.
        if (try device.getRawName(io, &buf)) |name| {
            const exact = name.len + 1;
            try std.testing.expect(try device.getRawName(io, buf[0..exact]) != null);
            try std.testing.expectError(
                error.BufferTooSmall,
                device.getRawName(io, buf[0 .. exact - 1]),
            );
        }

        const size = try device.getReportDescriptorSize(io);
        try std.testing.expect(size <= max_report_descriptor_size);
        const bytes = try device.getReportDescriptor(io, descriptor[0..size]);
        try std.testing.expectEqual(@as(usize, size), bytes.len);

        checked += 1;
    }

    // Nothing attached, or no permission to open any of it.
    if (checked == 0) return error.SkipZigTest;
}
