// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Talk to USB and Bluetooth HID devices on Linux through the kernel's
//! `hidraw` interface, in pure Zig and without linking the C hidapi library.
//! The requests go straight to `/dev/hidraw*` as `HIDIOC*` ioctls.
//!
//! This is the root of the `hidapi` module, so a dependent reaches everything
//! here through `@import("hidapi")`. There are three types: `Device` is an
//! open device and carries every operation, `DeviceInfo` is what identifies
//! one, and `DeviceInfoIterator` finds the devices that are attached.
//!
//! Every call takes a `std.Io` as its first argument and dispatches its
//! syscall through it, so the caller decides how waiting is done. Declaring
//! `main` with a `std.process.Init` parameter is the easiest way to come by
//! one; a library that is not `main` constructs its own.
//!
//! ```
//! var it: hidapi.DeviceInfoIterator = .init;
//! while (try it.next(io)) |info| {
//!     defer info.device.close(io);
//!
//!     var buf: [256]u8 = undefined;
//!     const name = try info.device.getRawName(io, &buf) orelse "(unnamed)";
//!     std.debug.print("{x:0>4}:{x:0>4} [{t}] {s}\n", .{
//!         info.vendor,
//!         info.product,
//!         info.bustype,
//!         name,
//!     });
//! }
//! ```
//!
//! `/dev/hidraw*` is normally root only, so opening a device as an
//! unprivileged process fails with `error.HIDDeviceNoAccess` until a udev rule
//! grants access; the README has one to copy.

const std = @import("std");

/// An open `hidraw` device, and every operation on one.
pub const Device = @import("Device.zig");

/// What identifies a device: its bus, vendor ID and product ID, together with
/// the open `Device` they were read from.
pub const DeviceInfo = @import("DeviceInfo.zig");

/// An iterator over the `hidraw` devices attached to the system.
pub const DeviceInfoIterator = @import("DeviceInfoIterator.zig");

test {
    // Referencing the three types here is what draws their files into the
    // compilation, which is in turn what makes their own tests part of the
    // test build.
    std.testing.refAllDecls(@This());
}
