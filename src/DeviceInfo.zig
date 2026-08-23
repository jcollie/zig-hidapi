// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const DeviceInfo = @This();

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.device_info);

const ioctl = @import("ioctl.zig");

const Device = @import("Device.zig");

/// The hidraw device.
device: Device,

/// The bus type.
bustype: ioctl.BUS,

/// The vendor ID.
vendor: u16,

/// The product ID.
product: u16,

pub fn init(device: Device, info: *const ioctl.hidraw_devinfo) DeviceInfo {
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
