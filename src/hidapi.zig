// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Talk to USB and Bluetooth HID devices, in Zig, without linking the C
//! hidapi library.
//!
//! This is the root of the `hidapi` module, so a dependent reaches everything
//! here through `@import("hidapi")`. The shape of a program using it is:
//! enumerate to find the device you want, keep its `DeviceId`, open it, and
//! exchange reports.
//!
//! ```
//! var scratch: [hidapi.Enumerator.recommended_scratch]u8 = undefined;
//! var devices: hidapi.Enumerator = undefined;
//! try devices.init(io, &scratch, .{ .vendor_id = 0x046d });
//! defer devices.deinit(io);
//!
//! const id = while (try devices.next(io)) |info| {
//!     if (info.usage_page == 0xFF00) break info.id;
//! } else return error.NotFound;
//!
//! var dev: hidapi.Device = undefined;
//! try dev.open(io, id, .{});
//! defer dev.close(io);
//! ```
//!
//! Every call takes a `std.Io` as its first argument and dispatches its
//! syscall through it, so the caller decides how waiting is done. Declaring
//! `main` with a `std.process.Init` parameter is the easiest way to come by
//! one; a library that is not `main` constructs its own.
//!
//! Nothing here allocates. Where a buffer is needed -- the report itself, the
//! enumerator's scratch, a device's input queue -- it is the caller's.
//!
//! ## Supported systems
//!
//! Linux, through the kernel's
//! [hidraw](https://docs.kernel.org/hid/hidraw.html) interface and
//! `/sys/class/hidraw`. Building for anything else is a compile error naming
//! what is supported; see `backend.zig`.
//!
//! ## Permissions
//!
//! Enumeration needs none. Opening a device does: `/dev/hidraw*` is root-only
//! until a udev rule says otherwise, and until then `Device.open` answers
//! `error.AccessDenied`. The README has a rule to copy.
//!
//! The source, that rule, and the issue tracker are at
//! [git.jcollie.dev/jeff/zig-hidapi](https://git.jcollie.dev/jeff/zig-hidapi).

const std = @import("std");

/// An open HID device, and every operation on one.
pub const Device = @import("Device.zig");

/// Everything known about a device without talking to it.
pub const DeviceInfo = @import("DeviceInfo.zig");

/// What names a device to the operating system; all `Device.open` needs.
pub const DeviceId = @import("DeviceId.zig");

/// Walks the devices attached to the system.
pub const Enumerator = @import("Enumerator.zig");

/// The transport a device is attached by.
pub const BusType = @import("bus_type.zig").BusType;

/// A short string a device reported about itself, held by value.
pub const Str = @import("Str.zig");

/// Just enough of a report descriptor parser to say what a device is for.
pub const descriptor = @import("descriptor.zig");

/// The largest report descriptor any device reports.
pub const max_report_descriptor_len = Device.max_report_descriptor_len;

const errors = @import("errors.zig");

pub const DeviceError = errors.DeviceError;
pub const OpenError = errors.OpenError;
pub const EnumerateError = errors.EnumerateError;
pub const ReadError = errors.ReadError;
pub const WriteError = errors.WriteError;
pub const ReportError = errors.ReportError;
pub const DescriptorError = errors.DescriptorError;
/// Every error any call in this library can return.
pub const AnyError = errors.AnyError;

test {
    // Referencing the types here is what draws their files into the
    // compilation, which is in turn what makes their own tests part of the
    // test build.
    std.testing.refAllDecls(@This());
    _ = @import("backend.zig");
    _ = @import("backend/contract.zig");
    _ = errors;
    _ = @import("io_op.zig");
}
