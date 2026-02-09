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

pub fn next(self: *DeviceInfoIterator, io: std.Io) !?DeviceInfo {
    if (self.index >= 64) return null;
    while (self.index < 64) {
        defer self.index += 1;
        const device = Device.open(io, self.index) catch continue;
        defer device.close(io);
        return device.getDeviceInfo(io) catch continue;
    }
    return null;
}

test "enumerate" {
    const io = std.testing.io;
    var it: DeviceInfoIterator = .init;
    while (try it.next(io)) |di| {
        var buf: [256]u8 = undefined;
        const d = try di.open(io);
        {
            const name = try d.getPhysicalLocation(io, &buf);
            std.debug.print("name: {s}\n", .{name});
        }
        {
            const name = try d.getRawName(io, &buf);
            std.debug.print("name: {s}\n", .{name});
        }
    }
}
