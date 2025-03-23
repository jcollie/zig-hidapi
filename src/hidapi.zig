const std = @import("std");

pub const c = @cImport({
    @cInclude("hidapi/hidapi.h");
});

pub const Device = @import("Device.zig");
pub const DeviceInfo = @import("DeviceInfo.zig");
pub const DeviceInfoIterator = @import("DeviceInfoIterator.zig");

pub const Errors = InitErrors || ExitErrors;

pub const MAX_REPORT_DESCRIPTOR_SIZE = c.HID_API_MAX_REPORT_DESCRIPTOR_SIZE;

pub const HidBusType = enum(c.hid_bus_type) {
    UNKNOWN = c.HID_API_BUS_UNKNOWN,
    USB = c.HID_API_BUS_USB,
    BLUETOOTH = c.HID_API_BUS_BLUETOOTH,
    I2C = c.HID_API_BUS_I2C,
    SPI = c.HID_API_BUS_SPI,
    _,
};

pub const InitErrors = error{
    HidApiInitError,
};

pub fn init() InitErrors!void {
    const ret = c.hid_init();
    if (ret != 0) return error.HidApiInitError;
}

pub const ExitErrors = error{
    HidApiExitError,
};

pub fn exit() ExitErrors!void {
    const ret = c.hid_exit();
    if (ret != 0) return error.HidApiExitError;
}

pub fn getError(alloc: std.mem.Allocator) ![]const u8 {
    const err = try fromWCharAlloc(alloc, c.hid_error(null));
    if (err) |e| return e;
    return "";
}

pub fn enumerate(vendor_id: c_ushort, product_id_: ?c_ushort) !DeviceInfoIterator {
    const product_id = product_id_ orelse 0x0000;
    const device_info: ?*c.hid_device_info = c.hid_enumerate(vendor_id, product_id);

    return .{
        .start = device_info,
        .current = device_info,
    };
}

pub fn version() std.SemanticVersion {
    if (c.hid_version()) |v| {
        return .{
            .major = @intCast(v.*.major),
            .minor = @intCast(v.*.minor),
            .patch = @intCast(v.*.patch),
        };
    }
    return .{ .major = 0, .minor = 0, .patch = 0 };
}

test "version-1" {
    try std.testing.expectEqual(
        std.SemanticVersion{
            .major = 0,
            .minor = 14,
            .patch = 0,
        },
        version(),
    );
}

pub fn version_str() []const u8 {
    return std.mem.span(c.hid_version_str());
}

test "version-2" {
    const v = version_str();
    try std.testing.expectEqualStrings("0.14.0", v);
}

pub fn fromWCharAlloc(alloc: std.mem.Allocator, wide_string: [*c]const c.wchar_t) !?[]u8 {
    if (wide_string == null) return null;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(alloc);
    var writer = output.writer(alloc);
    var index: usize = 0;
    while (wide_string[index] != 0) : (index += 1) {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(@intCast(wide_string[index]), &buf);
        try writer.writeAll(buf[0..len]);
    }
    return try output.toOwnedSlice(alloc);
}

pub fn toWCharAlloc(alloc: std.mem.Allocator, string: []const u8) ![*c]c.wchar_t {
    var list: std.ArrayList(c.wchar_t) = .empty;
    errdefer list.deinit(alloc);
    var iter = (try std.unicode.Utf8View.init(string)).iterator();
    while (iter.nextCodepoint()) |codepoint| {
        try list.append(alloc, @intCast(codepoint));
    }
    return try list.toOwnedSliceSentinel(alloc, 0);
}

pub fn toWChar(string: []const u8, buffer: []c.wchar_t) ![*c]c.wchar_t {
    var iter = (try std.unicode.Utf8View.init(string)).iterator();
    var index: usize = 0;
    while (iter.nextCodepoint()) |codepoint| : (index += 1) {
        buffer[index] = @intCast(codepoint);
    }
    buffer[index] = 0;
    return buffer.ptr;
}

test {
    std.testing.refAllDecls(@This());
}
