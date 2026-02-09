const DeviceInfoIterator = @This();

const std = @import("std");

const log = std.log.scoped(.device_info_iterator);

const hidapi = @import("hidapi.zig");
const DeviceInfo = @import("DeviceInfo.zig");

index: std.os.linux.dev_t = 0,

pub const init: DeviceInfoIterator = .{};

pub fn next(self: *DeviceInfoIterator) !?DeviceInfo {
    if (self.index >= 64) return null;
    while (self.index < 64) {
        defer self.index += 1;
        return try DeviceInfo.init(self.index) orelse continue;
    }
    return null;
}

test "enumerate" {
    var it: DeviceInfoIterator = .init;
    while (try it.next()) |di| {
        log.warn("{d} {x:0>4} {x:0>4}", .{
            di.minor,
            di.vendor,
            di.product,
        });
        if (di.vendor == 0x0fd9 and di.product == 0x0084) {
            var buf: [32]u8 = @splat(0);
            buf[0] = 0x06;
            const device = try di.open();
            defer device.close();
            const result = try device.getFeatureReport(&buf);
            if (result.len < 2) {
                log.warn("not long enough (1)", .{});
                continue;
            }
            const len = result[1];
            if (result.len < 2 + len) {
                log.warn("not long enough (2)", .{});
                continue;
            }
            const serial = result[2 .. 2 + len];
            log.warn("{s}", .{serial});
        }
    }
}
