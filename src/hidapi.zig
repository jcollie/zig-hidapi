const std = @import("std");

const hidapi = @cImport({
    @cInclude("hidapi/hidapi.h");
});

const MAX_REPORT_DESCRIPTOR_SIZE = hidapi.HID_API_MAX_REPORT_DESCRIPTOR_SIZE;

const HidBusType = enum(hidapi.hid_bus_type) {
    UNKNOWN = hidapi.HID_API_BUS_UNKNOWN,
    USB = hidapi.HID_API_BUS_USB,
    BLUETOOTH = hidapi.HID_API_BUS_BLUETOOTH,
    I2C = hidapi.HID_API_BUS_I2C,
    SPI = hidapi.HID_API_BUS_SPI,
    _,
};

pub fn from_wchar(alloc: std.mem.Allocator, wide_string: [*c]const hidapi.wchar_t) !?[]u8 {
    if (wide_string == null) return null;
    var output = std.ArrayList(u8).init(alloc);
    var writer = output.writer();
    var index: usize = 0;
    while (wide_string[index] != 0) : (index += 1) {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(@intCast(wide_string[index]), &buf);
        try writer.writeAll(buf[0..len]);
    }
    return try output.toOwnedSlice();
}

pub fn to_wchar(alloc: std.mem.Allocator, string: []const u8) ![*c]hidapi.wchar_t {
    var list = std.ArrayList(hidapi.wchar_t).init(alloc);
    errdefer list.deinit();
    var iter = std.unicode.Utf8View.init(string);
    while (iter.next()) |codepoint| {
        try list.append(@intCast(codepoint));
    }
    return list.toOwnedSliceSentinel(0);
}

pub fn err(alloc: std.mem.Allocator) ![]const u8 {
    return try from_wchar(alloc, hidapi.hid_error(null));
}

const Device = struct {
    device: ?*hidapi.hid_device,

    const Self = @This();

    pub fn err(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
        return try from_wchar(alloc, hidapi.hid_error(self.device));
    }

    /// Sends a HID feature report to an open HID device.
    pub fn send_feature_report(self: Self, data: []const u8) !c_int {
        return hidapi.hid_send_feature_report(self.device, data.ptr, data.len);
    }

    pub fn get_feature_report(self: Self, report_id: u8, buffer: []u8) ![]const u8 {
        buffer[0] = report_id;
        const length = hidapi.hid_get_feature_report(self.device, buffer.ptr, buffer.len);
        if (length < 0) return error.HIDAPiError;
        return buffer[0..length];
    }

    pub fn get_input_report(self: @This(), report_id: u8, buffer: []u8) ![]const u8 {
        buffer[0] = report_id;
        const result = hidapi.hid_get_input_report(self.device, buffer.ptr, buffer.len);
        if (result < 1) return error.HIDApiError;
        return buffer[0..result];
    }
    pub fn set_nonblocking(self: @This(), nonblocking: bool) !void {
        const result = hidapi.hid_set_nonblocking(self.device, if (nonblocking) 1 else 0);
        if (result < 0) return error.HIDApiError;
    }

    pub fn write(self: @This(), data: []const u8) !c_int {
        const result = hidapi.hid_write(self.device, data.ptr, data.len);
        if (result < 0) return error.HIDApiError;
        return result;
    }

    pub fn read_timeout(self: @This(), buffer: []u8, milliseconds: c_int) !?[]const u8 {
        const result = hidapi.hid_read_timeout(self.device, buffer.ptr, buffer.len, milliseconds);
        if (result < 0) return error.HIDApiError;
        if (result == 0) return null;
        return buffer[0..result];
    }

    pub fn read(self: @This(), buffer: []u8) !?[]const u8 {
        const result = hidapi.hid_read(self.device, buffer.ptr, buffer.len);
        if (result < 0) return error.HIDApiError;
        if (result == 0) return null;
        return buffer[0..result];
    }

    pub fn get_indexed_string(self: @This(), string_index: c_int, buffer: []hidapi.wchar_t) !void {
        const result = hidapi.hid_get_indexed_string(self.device, string_index, buffer.ptr, buffer.len);
        if (result < 0) return error.HIDApiError;
    }

    pub fn get_report_descriptor(self: @This(), buffer: []u8) ![]const u8 {
        const result = hidapi.hid_get_report_descriptor(self.device, buffer.ptr, buffer.len);
        if (result < 0) return error.HIDApiError;
        return buffer[0..result];
    }

    pub fn close(self: *Self) void {
        hidapi.hid_close(self.device);
        self.device = null;
    }
};

pub fn open(alloc: std.mem.Allocator, vendor_id: c_ushort, product_id: c_ushort, serial_number: ?[]const u8) !Device {
    const s = if (serial_number) |s| try to_wchar(alloc, s) else null;
    const device = hidapi.hid_open(vendor_id, product_id, s);
    if (device) |_| return .{ .device = device };
    return error.HIDApiError;
}

pub fn open_path(path: [:0]const u8) !Device {
    const d = Device{ .device = hidapi.hid_open_path(path.ptr) };
    if (d.device != null) return d;
    return error.HIDApiError;
}

const DeviceInfo = struct {
    vendor_id: u16,
    product_id: u16,
    path: []u8,
    serial_number: ?[]u8,
    release_number: c_ushort,
    manufacturer: ?[]u8,
    product: ?[]u8,
    usage_page: c_ushort,
    usage: c_ushort,
    interface_number: c_int,
    bus_type: HidBusType,

    const Self = @This();

    pub fn open(self: Self) !Device {
        const d = Device{
            .device = hidapi.hid_open_path(self.path),
        };
        if (d.device) return d;
        const err = hidapi.hid_error(null);
        d.err = try from_wchar(err, &d.err);
        return d;
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{x:0>4} {x:0>4} {s} '{?s}'\n", .{ self.vendor_id, self.product_id, self.path, self.serial_number });
        try writer.print("Manufacturer: {?s}\n", .{self.manufacturer});
        try writer.print("Product:      {?s}\n", .{self.product});
        try writer.print("Release:      0x{x}\n", .{self.release_number});
        try writer.print("Interface:    0x{x}\n", .{self.interface_number});
        try writer.print("Usage (page): 0x{x} (0x{x})\n", .{ self.usage, self.usage_page });
        try writer.print("Bus type:     {} ({})\n", .{
            self.bus_type,
            @intFromEnum(self.bus_type),
        });
    }
};

const DeviceInfos = struct {
    arena: std.heap.ArenaAllocator,
    devices: []DeviceInfo,

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }
};

pub fn enumerate(allocator: std.mem.Allocator, vendor_id: c_ushort, product_id: c_ushort) !DeviceInfos {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const alloc = arena.allocator();

    var dl = std.ArrayList(DeviceInfo).init(alloc);

    var current: ?*hidapi.hid_device_info = hidapi.hid_enumerate(vendor_id, product_id);
    defer hidapi.hid_free_enumeration(current);

    while (current) |hid_device_info| {
        try dl.append(.{
            .vendor_id = hid_device_info.vendor_id,
            .product_id = hid_device_info.product_id,
            .release_number = hid_device_info.release_number,
            .path = try alloc.dupe(u8, std.mem.span(hid_device_info.path)),
            .serial_number = try from_wchar(alloc, hid_device_info.serial_number),
            .manufacturer = try from_wchar(alloc, hid_device_info.manufacturer_string),
            .product = try from_wchar(alloc, hid_device_info.product_string),
            .usage_page = hid_device_info.usage_page,
            .usage = hid_device_info.usage,
            .interface_number = hid_device_info.interface_number,
            .bus_type = @enumFromInt(hid_device_info.bus_type),
        });
        current = hid_device_info.next;
    }

    return .{
        .arena = arena,
        .devices = try dl.toOwnedSlice(),
    };
}

pub fn init() !void {
    const ret = hidapi.hid_init();
    if (ret != 0) return error.HidApiInitError;
}

pub fn exit() !void {
    const ret = hidapi.hid_exit();
    if (ret != 0) return error.HidApiExitError;
}

pub fn version() struct { major: c_int, minor: c_int, patch: c_int } {
    if (hidapi.hid_version()) |v| {
        return .{
            .major = v.*.major,
            .minor = v.*.minor,
            .patch = v.*.patch,
        };
    }
    return .{ .major = 0, .minor = 0, .patch = 0 };
}

test "version-1" {
    const v = version();
    std.debug.print("\n{} {} {}\n", .{ v.major, v.minor, v.patch });
    try std.testing.expectEqual(@as(i32, 0), v.major);
    try std.testing.expectEqual(@as(i32, 14), v.minor);
    try std.testing.expectEqual(@as(i32, 0), v.patch);
}

pub fn version_str() []const u8 {
    return std.mem.span(hidapi.hid_version_str());
}

test "version-2" {
    const v = version_str();
    std.debug.print("\n{s}\n", .{v});
    try std.testing.expectEqualStrings("0.14.0", v);
}

test "enumerate" {
    try init();
    defer exit() catch unreachable;
    const device_infos = try enumerate(std.testing.allocator);
    defer device_infos.deinit();
    for (device_infos.devices) |device_info| {
        std.debug.print("{}\n\n", .{device_info});
    }
}
