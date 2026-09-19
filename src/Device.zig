// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! An open HID device, and every operation on one.
//!
//! ```
//! var dev: hidapi.Device = undefined;
//! try dev.open(io, info.id, .{});
//! defer dev.close(io);
//!
//! var buf: [64]u8 = undefined;
//! const report = try dev.read(io, &buf);
//! ```
//!
//! A `Device` is storage the caller owns and uses through a pointer, and it
//! must not be moved between `open` and `close`. That is not the shape a
//! two-word handle would want, and it is not negotiable: on macOS IOKit is
//! handed this pointer at open time and calls back on it from another thread
//! for the life of the device. One signature for all four backends is worth
//! more than a smaller type on the three where it would fit.
//!
//! This is the portable half. It holds the conventions that are the same
//! everywhere -- the report ID in the first byte, what an empty answer means,
//! which errors callers see -- and forwards the system calls to the backend
//! for the operating system being built for. `src/backend.zig` picks that
//! backend and `src/backend/contract.zig` says what it has to provide.
//!
//! Every method takes a `std.Io` and dispatches its syscall through it rather
//! than issuing it directly, which leaves the choice of how to wait up to the
//! caller's `Io` implementation.
//!
//! **Every buffer here begins with the report ID**, which is `0x00` for a
//! device that does not use numbered reports. A sixteen byte report is
//! seventeen bytes of buffer. This is the convention the HID specification
//! forces and every HID library shares; forgetting it is the single most
//! common way to get a device to ignore you.

const Device = @This();

const std = @import("std");

const backend = @import("backend.zig");
const errors = @import("errors.zig");
const DeviceId = @import("DeviceId.zig");
const DeviceInfo = @import("DeviceInfo.zig");

/// Backend state, inline, so that the library allocates nothing and the
/// storage is the caller's.
impl: backend.impl.Device,

/// How to open a device.
pub const OpenOptions = struct {
    /// Backing store for input reports that arrive before the caller asks for
    /// one.
    ///
    /// Only macOS and Windows queue in user space and need it: on macOS
    /// reports arrive on a callback whether anyone is reading or not, and on
    /// Windows the class driver's own ring is what this replaces. Linux and
    /// FreeBSD let the kernel do it -- hidraw buffers 64 reports on both --
    /// and ignore this entirely.
    ///
    /// `error.BufferTooSmall` if it cannot hold a single input report from the
    /// device being opened.
    input_queue: []u8 = &.{},

    /// Open the device exclusively, so that nothing else receives events from
    /// it while it is held.
    ///
    /// Off by default, which differs from the C hidapi: that library seizes
    /// the device on macOS for backward compatibility with its own history.
    /// Seizing stops the device working for everything else on the machine,
    /// and on a device the system has claimed it simply fails, so it is a
    /// thing to ask for rather than a thing to get.
    exclusive: bool = false,

    /// How long a control transfer may take before it is abandoned.
    ///
    /// Only macOS reads this, where a synchronous IOKit call cannot be
    /// cancelled and a wedged device would otherwise hold a task forever.
    request_timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .fromSeconds(5), .clock = .awake },
    },
};

/// Open the device that `id` names, as an `Enumerator` reported it.
///
/// Fails with `error.DeviceNotFound` when nothing answers to that ID -- which
/// includes a device unplugged since it was enumerated -- and
/// `error.AccessDenied` when the process may not talk to it, which is the
/// usual answer for an unprivileged process on Linux and FreeBSD and for a
/// keyboard or pointing device on Windows. The README says how to fix each.
///
/// The caller owns the device and must `close` it.
pub fn open(
    dev: *Device,
    io: std.Io,
    id: DeviceId,
    options: OpenOptions,
) errors.OpenError!void {
    return dev.impl.open(io, id, options);
}

/// Close the device. Errors are not reported, because there is nothing a
/// caller could do about one.
pub fn close(dev: *Device, io: std.Io) void {
    dev.impl.close(io);
}

/// Read an input report, waiting until the device sends one.
///
/// Input reports arrive on the interrupt IN endpoint. The first byte is the
/// report ID if the device uses numbered reports.
///
/// This waits indefinitely: a device that is simply idle, such as a mouse
/// nobody is touching, never returns from it. Use `readTimeout` for anything
/// that has to stay responsive, and cancel the task through `io` to stop a
/// read that is already waiting.
///
/// Returns `error.DeviceDisconnected` when the device goes away, which is the
/// ordinary end of a read loop rather than a failure to report.
pub fn read(dev: *Device, io: std.Io, buf: []u8) errors.ReadError![]u8 {
    return dev.impl.read(io, buf);
}

/// Read an input report, giving up after `timeout`.
///
/// Returns `null` when nothing arrived in time. Since `std.Io.Timeout` can be
/// a zero duration, that also covers a non-blocking poll:
///
/// ```
/// // Block for at most 250 ms.
/// const report = try dev.readTimeout(io, &buf, .{
///     .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake },
/// });
///
/// // Take whatever is already waiting, and do not wait.
/// const now = try dev.readTimeout(io, &buf, .{
///     .duration = .{ .raw = .zero, .clock = .awake },
/// });
/// ```
///
/// There is deliberately no non-blocking *mode* to set, the way the C hidapi
/// has one. A mode is a second way of saying what the timeout already says,
/// and it is state every backend would have to honour on every read path.
///
/// `null` and a zero-length report are different answers: a HID device may
/// legitimately send a report with no data, so the two cannot share a
/// representation. Taking a `Timeout` rather than a count of milliseconds
/// matters for the same reason it does elsewhere in `std.Io` -- a caller
/// polling several devices against one deadline says so once, instead of
/// recomputing a remaining duration per device and drifting.
pub fn readTimeout(
    dev: *Device,
    io: std.Io,
    buf: []u8,
    timeout: std.Io.Timeout,
) errors.ReadError!?[]u8 {
    return dev.impl.readTimeout(io, buf, timeout);
}

/// Write an output report.
///
/// The first byte of `report` is the report ID, `0x00` for a device that does
/// not use numbered reports. The report goes to the first OUT endpoint if the
/// device has one, and over the control endpoint if it does not.
pub fn write(dev: *Device, io: std.Io, report: []const u8) errors.WriteError!usize {
    return dev.impl.write(io, report);
}

/// Send a feature report over the control endpoint.
///
/// The first byte of `report` is the report ID.
pub fn sendFeatureReport(
    dev: *Device,
    io: std.Io,
    report: []const u8,
) errors.ReportError!usize {
    return dev.impl.sendFeatureReport(io, report);
}

/// Request a feature report over the control endpoint.
///
/// Set `buf[0]` to the report ID wanted. On return it is still there and the
/// report data starts at `buf[1]`, so `buf` has to be one byte longer than the
/// report.
pub fn getFeatureReport(dev: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
    return dev.impl.getFeatureReport(io, buf);
}

/// Request an input report over the control endpoint.
///
/// Slower than `read` on any device with a dedicated IN endpoint, and useful
/// for a different reason: it asks for a specific report by ID, which is how a
/// program learns a device's initial state before it starts listening for
/// changes.
pub fn getInputReport(dev: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
    return dev.impl.getInputReport(io, buf);
}

/// The size in bytes of the device's HID report descriptor.
///
/// Returns `error.Unsupported` on Windows; see `getReportDescriptor`.
pub fn getReportDescriptorLen(dev: *Device, io: std.Io) errors.DescriptorError!u32 {
    return dev.impl.getReportDescriptorLen(io);
}

/// Copy the device's HID report descriptor into `buf`.
///
/// Size `buf` with `getReportDescriptorLen`, or use
/// `max_report_descriptor_len` to be sure it always fits.
///
/// Returns `error.Unsupported` on Windows, where the HID class driver keeps
/// only its own parsed form of the descriptor and does not serve the original
/// bytes to user mode at all. There is no way around that short of
/// reconstructing a descriptor from the parsed form, which produces something
/// equivalent but not identical, and this library would rather say it cannot
/// than hand back bytes the device never sent.
pub fn getReportDescriptor(
    dev: *Device,
    io: std.Io,
    buf: []u8,
) errors.DescriptorError![]const u8 {
    return dev.impl.getReportDescriptor(io, buf);
}

/// Input reports thrown away because the queue was full, since this was last
/// asked, resetting the count.
///
/// Always zero on Linux, FreeBSD and Windows, where the kernel or the class
/// driver does the queueing and this library never sees a full buffer. On
/// macOS it is real: reports arrive on a callback whether anyone is reading or
/// not, so a program that falls behind loses them.
///
/// This exists because losing input silently is worse than losing it loudly.
/// The C hidapi caps its macOS queue at thirty reports and drops quietly,
/// which turns "my program is too slow" into "my device is flaky".
pub fn takeDroppedReports(dev: *Device) u64 {
    return dev.impl.takeDroppedReports();
}

/// The largest report descriptor any device reports, so a buffer this size
/// always holds one.
pub const max_report_descriptor_len = backend.impl.max_report_descriptor_len;

/// Fill `out` with what the open device says about itself.
///
/// This answers less than enumeration does, because it asks the HID device
/// rather than the system: on Linux `manufacturer` is not reported here at all
/// and `product` carries the vendor and product strings run together. A caller
/// that wants the full picture should keep the `DeviceInfo` the `Enumerator`
/// produced rather than re-reading it from the open device.
pub fn getInfo(
    dev: *Device,
    io: std.Io,
    out: *DeviceInfo,
) (errors.DeviceError || std.Io.Cancelable)!void {
    return dev.impl.getInfo(io, out);
}

test {
    // `std.testing.refAllDecls` is not recursive, so the root module
    // referencing this file does not reach these functions. Referencing them
    // here is what makes the semantic analyzer check every method body, which
    // catches errors in methods that no test happens to call.
    std.testing.refAllDecls(@This());
}

test "read-only operations against attached devices" {
    const io = std.testing.io;
    const Enumerator = @import("Enumerator.zig");

    var scratch: [Enumerator.recommended_scratch]u8 = undefined;
    var devices: Enumerator = undefined;
    try devices.init(io, &scratch, .{});
    defer devices.deinit(io);

    var descriptor: [max_report_descriptor_len]u8 = undefined;
    var checked: usize = 0;

    while (try devices.next(io)) |listed| {
        var dev: Device = undefined;
        // Enumeration needs no permission and opening does, so most devices
        // on an unprivileged run are listed and then refused. That is the
        // point of the split, and not a reason to fail the test.
        dev.open(io, listed.id, .{}) catch continue;
        defer dev.close(io);

        // Only side-effect-free calls belong here, because this runs against
        // whatever hardware happens to be attached. `read` waits for a report
        // that an idle device never sends, and `write` and `sendFeatureReport`
        // change device state, so all three are covered by the reference
        // above only.
        var opened: DeviceInfo = undefined;
        try dev.getInfo(io, &opened);

        // The device and the system have to agree about what it is. This is
        // the assertion that would catch the sysfs walk reading the wrong
        // parent, which is the one mistake in enumeration that produces
        // plausible answers rather than obvious ones.
        try std.testing.expectEqual(listed.vendor_id, opened.vendor_id);
        try std.testing.expectEqual(listed.product_id, opened.product_id);
        try std.testing.expectEqual(listed.native_bus, opened.native_bus);

        const len = try dev.getReportDescriptorLen(io);
        try std.testing.expect(len <= max_report_descriptor_len);
        const bytes = try dev.getReportDescriptor(io, descriptor[0..len]);
        try std.testing.expectEqual(@as(usize, len), bytes.len);

        // A buffer one byte short of the descriptor has to be reported rather
        // than quietly filled.
        if (len > 0) try std.testing.expectError(
            error.BufferTooSmall,
            dev.getReportDescriptor(io, descriptor[0 .. len - 1]),
        );

        checked += 1;
    }

    // Nothing attached, or no permission to open any of it.
    if (checked == 0) return error.SkipZigTest;
}
