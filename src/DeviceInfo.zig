// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const DeviceInfo = @This();

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.device_info);

const ioctl = @import("ioctl.zig");

const Device = @import("Device.zig");

/// The minor device number used to access the hidraw device.
minor: linux.dev_t,

/// The bus type.
bustype: ioctl.BUS,

/// The vendor ID.
vendor: u16,

/// The product ID.
product: u16,

pub fn init(minor: linux.dev_t, info: *const ioctl.hidraw_devinfo) DeviceInfo {
    return .{
        .minor = minor,
        .bustype = info.bustype,
        .vendor = info.vendor,
        .product = info.product,
    };
}

pub fn open(self: *const DeviceInfo) !Device {
    return try Device.open(self.minor);
}
