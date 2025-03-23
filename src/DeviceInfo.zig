const DeviceInfo = @This();

const std = @import("std");

const hidapi = @import("hidapi.zig");

vendor_id: c_ushort,
product_id: c_ushort,
path: []u8,
serial_number: ?[]u8,
release_number: c_ushort,
manufacturer: ?[]u8,
product: ?[]u8,
usage_page: c_ushort,
usage: c_ushort,
interface_number: c_int,
bus_type: hidapi.HidBusType,

pub fn init(alloc: std.mem.Allocator, hid_device_info: [*c]hidapi.c.hid_device_info) !DeviceInfo {
    return .{
        .vendor_id = hid_device_info.*.vendor_id,
        .product_id = hid_device_info.*.product_id,
        .release_number = hid_device_info.*.release_number,
        .path = try alloc.dupe(u8, std.mem.span(hid_device_info.*.path)),
        .serial_number = try hidapi.fromWCharAlloc(alloc, hid_device_info.*.serial_number),
        .manufacturer = try hidapi.fromWCharAlloc(alloc, hid_device_info.*.manufacturer_string),
        .product = try hidapi.fromWCharAlloc(alloc, hid_device_info.*.product_string),
        .usage_page = hid_device_info.*.usage_page,
        .usage = hid_device_info.*.usage,
        .interface_number = hid_device_info.*.interface_number,
        .bus_type = @enumFromInt(hid_device_info.*.bus_type),
    };
}

// pub fn open(self: Self) !Device {
//     const d = Device{
//         .device = hidapi.hid_open_path(self.path),
//     };
//     if (d.device) return d;
//     const err = hidapi.hid_error(null);
//     d.err = try from_wchar_alloc(err, &d.err);
//     return d;
// }

pub fn format(self: *const DeviceInfo, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
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

pub fn deinit(self: *DeviceInfo, alloc: std.mem.Allocator) void {
    alloc.free(self.path);
    alloc.free(self.serial_number);
    alloc.free(self.manufacturer);
    alloc.free(self.product);
}
