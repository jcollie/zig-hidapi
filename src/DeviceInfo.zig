const DeviceInfo = @This();

const std = @import("std");
const log = std.log.scoped(.hidapi);

const ioctl = @import("ioctl.zig");

minor: std.os.linux.dev_t,
vendor_id: u16,
product_id: u16,
serial: []const u8,
buf: [32]u8 = undefined,

pub fn init(minor: std.os.linux.dev_t) !?DeviceInfo {
    const fd = fd: {
        var buf: [std.fs.max_name_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/dev/hidraw{d}", .{minor});

        const rc = std.os.linux.open(
            path,
            .{
                .ACCMODE = .RDWR,
                .APPEND = true,
                .NONBLOCK = true,
            },
            0,
        );
        break :fd switch (std.os.linux.E.init(rc)) {
            .SUCCESS => break :fd @as(std.os.linux.fd_t, @intCast(rc)),
            .EXIST => return null,
            .ACCES => return null,
            else => |e| {
                log.err("problem: {s} {s}", .{ path, @tagName(e) });
                return error.OpenError;
            },
        };
    };
    defer _ = std.os.linux.close(fd);
    const vendor, const product = info: {
        var info = std.mem.zeroes(ioctl.hidraw_devinfo);
        const rc = std.os.linux.ioctl(fd, ioctl.HIDIOCGRAWINFO, @intFromPtr(&info));
        switch (std.os.linux.E.init(rc)) {
            .SUCCESS => break :info .{ info.vendor, info.product },
            else => |e| {
                log.err("problem: {s}", .{@tagName(e)});
                return error.HIDError;
            },
        }
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

// pub fn format(self: *const DeviceInfo, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
//     try writer.print("{x:0>4} {x:0>4} {s} '{?s}'\n", .{ self.vendor_id, self.product_id, self.path, self.serial_number });
//     try writer.print("Manufacturer: {?s}\n", .{self.manufacturer});
//     try writer.print("Product:      {?s}\n", .{self.product});
//     try writer.print("Release:      0x{x}\n", .{self.release_number});
//     try writer.print("Interface:    0x{x}\n", .{self.interface_number});
//     try writer.print("Usage (page): 0x{x} (0x{x})\n", .{ self.usage, self.usage_page });
//     try writer.print("Bus type:     {} ({})\n", .{
//         self.bus_type,
//         @intFromEnum(self.bus_type),
//     });
// }

// pub fn deinit(self: *DeviceInfo, alloc: std.mem.Allocator) void {
//     alloc.free(self.path);
//     alloc.free(self.serial_number);
//     alloc.free(self.manufacturer);
//     alloc.free(self.product);
// }
