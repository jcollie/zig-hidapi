// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Walks the HID devices attached to the system.
//!
//! ```
//! var scratch: [hidapi.Enumerator.recommended_scratch]u8 = undefined;
//! var devices: hidapi.Enumerator = undefined;
//! try devices.init(io, &scratch, .{});
//! defer devices.deinit(io);
//!
//! while (try devices.next(io)) |info| std.debug.print("{f}\n", .{info});
//! ```
//!
//! Enumerating does not open anything. That is a change from how this library
//! used to work, and it is what makes it portable: Windows refuses a
//! read-write open of a keyboard or a mouse outright, since the system holds
//! those exclusively, and macOS has no file descriptor to hand back at all. It
//! also means that on Linux an unprivileged process with no udev rule now sees
//! every device rather than none, because `/sys/class/hidraw` is readable
//! where `/dev/hidraw*` is not.
//!
//! The scratch buffer is the caller's, so this library allocates nothing.
//! `recommended_scratch` is a size that works; `min_scratch` is the floor
//! below which `init` returns `error.BufferTooSmall`. Both are per-backend,
//! because what the snapshot costs differs: Linux and FreeBSD read one device
//! at a time, while Windows takes the whole interface list in one call and
//! macOS copies a set of device references out of IOKit.

const Enumerator = @This();

const std = @import("std");

const backend = @import("backend.zig");
const errors = @import("errors.zig");
const DeviceInfo = @import("DeviceInfo.zig");

/// What to look for, and how much to find out about it.
pub const Options = struct {
    /// Report only devices with this vendor ID.
    vendor_id: ?u16 = null,
    /// Report only devices with this product ID.
    product_id: ?u16 = null,

    /// Fill in `usage_page` and `usage`.
    ///
    /// Free on Windows and macOS, which are told. On Linux and FreeBSD it
    /// means reading and walking a report descriptor for every device, which
    /// is most of what enumeration costs, so a caller that only wants to match
    /// on vendor and product can turn it off.
    usages: bool = true,

    /// Fill in `manufacturer`, `product`, `serial_number` and
    /// `physical_location`.
    ///
    /// Four extra sysfs reads per device on Linux. On Windows it is the
    /// difference between reading the device list and opening a handle to
    /// every device in it, so turning it off is worth real time on a machine
    /// with a lot of HID devices.
    strings: bool = true,
};

/// A scratch size that works on this target. Sized so that
/// `error.BufferTooSmall` does not happen in practice.
pub const recommended_scratch = backend.impl.Enumerator.recommended_scratch;

/// The smallest scratch this target's backend accepts.
pub const min_scratch = backend.impl.Enumerator.min_scratch;

impl: backend.impl.Enumerator,
/// Where `next` puts the device it found. Held here rather than returned by
/// value because a `DeviceInfo` is over a kilobyte, most of which a caller
/// filtering on vendor and product never looks at.
current: DeviceInfo,

/// Begin enumerating.
///
/// `scratch` has to be at least `min_scratch` bytes and belongs to the
/// enumerator until `deinit`. Call `deinit` even when `init` fails to find
/// anything: an empty system is a successful enumeration of nothing, not an
/// error.
pub fn init(
    self: *Enumerator,
    io: std.Io,
    scratch: []u8,
    options: Options,
) errors.EnumerateError!void {
    self.current = .empty;
    try self.impl.init(io, scratch, options);
}

/// Release whatever the enumeration held. The scratch buffer is the caller's
/// again afterwards.
pub fn deinit(self: *Enumerator, io: std.Io) void {
    self.impl.deinit(io);
}

/// The next device, or `null` when there are no more.
///
/// The result aliases storage inside the enumerator and is valid only until
/// the next call to `next` or to `deinit`. Copy the `DeviceInfo` to keep it,
/// or copy just its `id`, which is all `Device.open` needs and which is a
/// value with no lifetime of its own.
pub fn next(self: *Enumerator, io: std.Io) errors.EnumerateError!?*const DeviceInfo {
    return if (try self.impl.next(io, &self.current)) &self.current else null;
}

/// Find the first device matching `options` and copy its `DeviceInfo` out.
///
/// The common case -- a program that knows which device it wants -- written
/// once so that every caller does not repeat the loop and the `deinit`.
pub fn find(
    io: std.Io,
    scratch: []u8,
    options: Options,
    out: *DeviceInfo,
) errors.EnumerateError!bool {
    var self: Enumerator = undefined;
    try self.init(io, scratch, options);
    defer self.deinit(io);

    if (try self.next(io)) |info| {
        out.* = info.*;
        return true;
    }
    return false;
}

test "enumerate" {
    const io = std.testing.io;

    var scratch: [recommended_scratch]u8 = undefined;
    var devices: Enumerator = undefined;
    try devices.init(io, &scratch, .{});
    defer devices.deinit(io);

    const log = std.log.scoped(.enumerate);
    var seen: usize = 0;
    while (try devices.next(io)) |info| {
        seen += 1;
        log.info("{f} at {f}", .{ info, &info.id });

        // Whatever is attached, these have to hold for all of it.
        try std.testing.expect(info.id.slice().len > 0);
        try std.testing.expect(info.manufacturer.slice() == null or
            info.manufacturer.slice().?.len > 0);
    }

    // Unlike the old iterator, this one does not need permission to open
    // anything, so on a Linux machine with any HID device at all it finds
    // something even as an unprivileged user. A machine with none -- a CI
    // runner -- legitimately finds nothing.
    log.info("enumerated {d} devices", .{seen});
}

test "a scratch buffer below the floor is refused rather than overrun" {
    const io = std.testing.io;
    var too_small: [8]u8 = undefined;
    var devices: Enumerator = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        devices.init(io, &too_small, .{}),
    );
}

test "filtering on a vendor nothing has yields nothing" {
    const io = std.testing.io;
    var scratch: [recommended_scratch]u8 = undefined;
    var devices: Enumerator = undefined;
    // 0xFFFF is not an assigned USB vendor ID.
    try devices.init(io, &scratch, .{ .vendor_id = 0xFFFF });
    defer devices.deinit(io);
    try std.testing.expectEqual(@as(?*const DeviceInfo, null), try devices.next(io));
}

test {
    std.testing.refAllDecls(@This());
}
