const DeviceInfoIterator = @This();

const std = @import("std");

const hidapi = @import("hidapi.zig");
const DeviceInfo = @import("DeviceInfo.zig");

start: ?*hidapi.c.hid_device_info,
current: ?*hidapi.c.hid_device_info,

pub fn next(self: *DeviceInfoIterator, alloc: std.mem.Allocator) !?DeviceInfo {
    if (self.current) |current| {
        self.current = current.next;
        return try DeviceInfo.init(alloc, current);
    }
    return null;
}

pub fn deinit(self: *DeviceInfoIterator) void {
    if (self.start) |start| hidapi.c.hid_free_enumeration(start);
}
