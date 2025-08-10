const DeviceInfoIterator = @This();

const std = @import("std");

const hidapi = @import("hidapi.zig");
const DeviceInfo = @import("DeviceInfo.zig");

index: usize = 0,

pub fn next(self: *DeviceInfoIterator) !?DeviceInfo {
    var buf: [std.fs.max_name_bytes]u8 = undefined;
    if (self.index >= 64) return null;
    while (self.index < 64) {
        var buf: [std.fs.max_name_bytes]u8 = undefined;
        try std.fmt.bufPrintZ(&buf, "/dev/hidraw{d}", .{self.index});
    }
    return null;
}

pub fn deinit(self: *DeviceInfoIterator) void {}
