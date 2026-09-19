// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! End-to-end tests against a HID device this process invented.
//!
//! Everything asserted here is something we told the kernel, so it can be
//! checked exactly rather than described loosely. That is the difference
//! between these and the tests in `src/`, which run against whatever hardware
//! is attached and can only assert that the library agrees with itself.
//!
//! `/dev/uhid` is root-only, so on a workstation these report `SkipZigTest`.
//! They do their work in the NixOS virtual machine test, which is what CI
//! runs and where the suite is root.

const std = @import("std");
const hidapi = @import("hidapi");
const uhid = @import("uhid.zig");

/// A vendor-defined device with one eight byte input report, one output
/// report and one feature report, and no report ID item -- so every report is
/// unnumbered and leads with a zero byte, which is the case most likely to be
/// got wrong.
const report_descriptor = [_]u8{
    0x06, 0x00, 0xFF, // Usage Page (Vendor Defined 0xFF00)
    0x09, 0x01, // Usage (0x01)
    0xA1, 0x01, // Collection (Application)
    0x09, 0x02, //   Usage (0x02)
    0x15, 0x00, //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255)
    0x75, 0x08, //   Report Size (8)
    0x95, 0x08, //   Report Count (8)
    0x81, 0x02, //   Input (Data, Var, Abs)
    0x09, 0x03, //   Usage (0x03)
    0x91, 0x02, //   Output (Data, Var, Abs)
    0x09, 0x04, //   Usage (0x04)
    0xB1, 0x02, //   Feature (Data, Var, Abs)
    0xC0, // End Collection
};

/// 0x1209 is pid.codes, the vendor ID handed out for exactly this sort of
/// thing, and 0x0001 is its "test PID". Nothing real answers to the pair.
const vendor_id = 0x1209;
const product_id = 0x0001;

const device_name = "zig-hidapi virtual test device";
const device_uniq = "SERIAL-0001";
const device_phys = "zig-hidapi/virtual0";

const bus_usb = 0x03;

const feature_payload = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
const input_payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04 };

fn spec() uhid.Spec {
    return .{
        .name = device_name,
        .phys = device_phys,
        .uniq = device_uniq,
        .bus = bus_usb,
        .vendor = vendor_id,
        .product = product_id,
        .version = 0x0100,
        .report_descriptor = &report_descriptor,
    };
}

/// Keeps answering the kernel while the test's main task is blocked in an
/// ioctl that is waiting for one of those answers.
///
/// `Device.getFeatureReport` does not return until something replies to the
/// `UHID_GET_REPORT` the kernel raises here, so the two halves genuinely have
/// to make progress at once. `Io.Group.async` is allowed to run a task
/// eagerly and serially, which would deadlock; `concurrent` is the one that
/// promises otherwise.
fn pump(io: std.Io, device: *uhid.VirtualDevice, stop: *std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        const event = device.poll() catch break;
        if (event == null) {
            // Nothing waiting. The kernel gives a `UHID_GET_REPORT` five
            // seconds before it gives up on us, so this interval only has to
            // be small next to that.
            io.sleep(.fromMilliseconds(1), .awake) catch break;
        }
    }
}

/// Wait for the kernel to publish the virtual device as a hidraw node.
///
/// Creation is asynchronous: `UHID_CREATE2` returns as soon as the request is
/// queued, and the node appears when the HID core has probed the device.
fn waitForDevice(io: std.Io, out: *hidapi.DeviceInfo) !void {
    var scratch: [hidapi.Enumerator.recommended_scratch]u8 = undefined;

    var waited_ms: usize = 0;
    while (waited_ms < 5000) : (waited_ms += 10) {
        if (try hidapi.Enumerator.find(
            io,
            &scratch,
            .{ .vendor_id = vendor_id, .product_id = product_id },
            out,
        )) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.VirtualDeviceNeverAppeared;
}

test "a virtual device is enumerated with everything it was created with" {
    const io = std.testing.io;

    var device = uhid.VirtualDevice.create(spec()) catch |err| switch (err) {
        // No `uhid` module, or not root. Both are the ordinary state of a
        // developer's machine.
        error.UhidNotAvailable, error.UhidNoAccess => return error.SkipZigTest,
        else => return err,
    };
    defer device.destroy();

    var info: hidapi.DeviceInfo = undefined;
    try waitForDevice(io, &info);

    try std.testing.expectEqual(@as(u16, vendor_id), info.vendor_id);
    try std.testing.expectEqual(@as(u16, product_id), info.product_id);
    try std.testing.expectEqual(hidapi.BusType.usb, info.bus_type);
    try std.testing.expectEqual(@as(u16, bus_usb), info.native_bus);

    // The name and uniq come back through `HID_NAME` and `HID_UNIQ` in the
    // `uevent` file, which is the path that matters: this device has no USB
    // ancestors, so the manufacturer walk finds nothing and the fallbacks are
    // what answer.
    try std.testing.expectEqualStrings(device_name, info.product.slice().?);
    try std.testing.expectEqualStrings(device_uniq, info.serial_number.slice().?);
    try std.testing.expectEqualStrings(device_phys, info.physical_location.slice().?);

    // A `uhid` device claims to be on USB but has no `usb_device` above it in
    // sysfs, so every attribute of that walk is absent. Reporting nothing is
    // the right answer and is what the `error.FileNotFound` path exists for;
    // anything else would mean the walk found some *other* device's files.
    try std.testing.expectEqual(@as(?[]const u8, null), info.manufacturer.slice());
    try std.testing.expectEqual(@as(?u8, null), info.interface_number);

    // Read out of the report descriptor by the walker in `descriptor.zig`,
    // without opening anything.
    try std.testing.expectEqual(@as(u16, 0xFF00), info.usage_page);
    try std.testing.expectEqual(@as(u16, 0x0001), info.usage);

    try std.testing.expect(std.mem.startsWith(u8, info.id.slice(), "/dev/hidraw"));
}

test "reports round trip through a virtual device" {
    const io = std.testing.io;

    var device = uhid.VirtualDevice.create(spec()) catch |err| switch (err) {
        error.UhidNotAvailable, error.UhidNoAccess => return error.SkipZigTest,
        else => return err,
    };
    defer device.destroy();
    device.feature_report = &feature_payload;

    var info: hidapi.DeviceInfo = undefined;
    try waitForDevice(io, &info);

    var handle: hidapi.Device = undefined;
    try handle.open(io, info.id, .{});
    defer handle.close(io);

    // The descriptor has to come back byte for byte. This is the assertion
    // that would catch `HIDIOCGRDESC` being handed the wrong size, which
    // otherwise produces a short read that looks plausible.
    var descriptor: [hidapi.max_report_descriptor_len]u8 = undefined;
    const len = try handle.getReportDescriptorLen(io);
    try std.testing.expectEqual(@as(u32, report_descriptor.len), len);
    try std.testing.expectEqualSlices(
        u8,
        &report_descriptor,
        try handle.getReportDescriptor(io, descriptor[0..len]),
    );

    var stop: std.atomic.Value(bool) = .init(false);
    var responder = try io.concurrent(pump, .{ io, &device, &stop });

    {
        // An input report the device sends of its own accord. hidraw buffers
        // it, so sending before reading is deterministic where the other
        // order would be a race.
        try device.sendInput(&input_payload);

        var buf: [64]u8 = undefined;
        const got = try handle.read(io, &buf);
        try std.testing.expectEqualSlices(u8, &input_payload, got);
    }

    {
        // A feature report the host asks for. The first byte is the report
        // ID -- zero, because this descriptor declares no report ID item --
        // and the payload follows it, so the buffer is one byte longer than
        // the report.
        var buf: [feature_payload.len + 1]u8 = undefined;
        buf[0] = 0x00;
        const got = try handle.getFeatureReport(io, &buf);
        try std.testing.expectEqual(@as(usize, feature_payload.len + 1), got.len);
        try std.testing.expectEqual(@as(u8, 0x00), got[0]);
        try std.testing.expectEqualSlices(u8, &feature_payload, got[1..]);
    }

    // A feature report the host sends down, which the device sees verbatim
    // including the leading report ID.
    const sent = [_]u8{ 0x00, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x01, 0x02 };
    _ = try handle.sendFeatureReport(io, &sent);

    stop.store(true, .release);
    responder.await(io);

    try std.testing.expectEqualSlices(u8, &sent, device.lastOutput());
}

test {
    std.testing.refAllDecls(@This());
    _ = uhid;
}
