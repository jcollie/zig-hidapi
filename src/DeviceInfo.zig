// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Identifying information for a HID device: the bus it is attached to, its
//! vendor ID and its product ID, as the backend reports them in one call --
//! a single `HIDIOCGRAWINFO` ioctl on Linux.
//!
//! A `DeviceInfo` also carries the open `Device` it was read from, so that
//! code enumerating devices can pick the one it wants and keep using it
//! without reopening. The device is not owned by the `DeviceInfo`; whoever
//! opened it still has to `close` it.
//!
//! Obtain one with `Device.getDeviceInfo`, or by iterating with
//! `DeviceInfoIterator`.

const DeviceInfo = @This();

const std = @import("std");

const impl = @import("backend.zig").impl;
const Device = @import("Device.zig");

/// The open device this information was read from.
///
/// Still owned by whoever opened it, and still has to be closed.
device: Device,

/// The bus the device is attached to.
///
/// Non-exhaustive, because the system may report a bus this library does not
/// name yet.
bustype: impl.BUS,

/// The vendor ID (VID).
vendor: u16,

/// The product ID (PID).
product: u16,

/// Pair `device` with the bus, vendor and product the backend just read from
/// it.
///
/// `info` is only read from, and is not referenced after this returns.
/// Callers normally go through `Device.getDeviceInfo` instead of calling
/// this directly.
pub fn init(device: Device, info: *const impl.DevInfo) DeviceInfo {
    return .{
        .device = device,
        .bustype = info.bustype,
        .vendor = info.vendor,
        .product = info.product,
    };
}

test {
    std.testing.refAllDecls(@This());
}
