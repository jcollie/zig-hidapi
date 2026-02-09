// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const DeviceInfoIterator = @This();

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.device_info_iterator);

const hidapi = @import("hidapi.zig");
const Device = @import("Device.zig");
const DeviceInfo = @import("DeviceInfo.zig");

index: linux.dev_t = 0,

pub const init: DeviceInfoIterator = .{};

pub fn next(self: *DeviceInfoIterator) !?DeviceInfo {
    if (self.index >= 64) return null;
    while (self.index < 64) {
        defer self.index += 1;
        const device = Device.open(self.index) catch continue;
        defer device.close();
        return device.getDeviceInfo() catch continue;
    }
    return null;
}

test "enumerate" {
    var it: DeviceInfoIterator = .init;
    while (try it.next()) |di| {
        _ = di;
    }
}
