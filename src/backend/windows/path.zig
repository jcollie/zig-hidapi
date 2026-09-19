// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reading a Windows device interface path.
//!
//! Every HID interface path spells out the vendor ID, the product ID and, for
//! a composite device, the USB interface number, and it contains the device
//! instance ID as a substring. So a good deal of what a caller wants to know
//! can be had from the string alone, without opening a handle -- which is what
//! lets a filtered enumeration skip a device it would have had to open first.
//!
//! This is separate from `windows.zig` because none of it is Win32: it is
//! string work that happens to be about Windows. Keeping it apart means these
//! tests run on whatever machine the suite runs on, rather than only on a
//! Windows one, and means they do not drag in the `zigwin32` dependency -- a
//! lazy dependency a Linux build has no reason to fetch.

const std = @import("std");

const BusType = @import("../../bus_type.zig").BusType;

/// The transport a device instance ID names.
///
/// Windows does not report a bus number the way Linux and FreeBSD do; what it
/// has is the parent device node's instance ID, whose prefix says which
/// enumerator produced it.
pub fn busTypeFromInstanceId(id: []const u8) BusType {
    const table = [_]struct { prefix: []const u8, bus: BusType }{
        .{ .prefix = "USB\\", .bus = .usb },
        .{ .prefix = "BTHENUM\\", .bus = .bluetooth },
        .{ .prefix = "BTHLEDEVICE\\", .bus = .bluetooth },
        .{ .prefix = "BTHLE\\", .bus = .bluetooth },
        .{ .prefix = "BTH\\", .bus = .bluetooth },
        .{ .prefix = "HIDI2C\\", .bus = .i2c },
        .{ .prefix = "I2C\\", .bus = .i2c },
        .{ .prefix = "SPB\\", .bus = .spi },
        .{ .prefix = "ROOT\\", .bus = .virtual },
    };
    for (table) |entry| {
        if (std.ascii.startsWithIgnoreCase(id, entry.prefix)) return entry.bus;
    }
    return if (id.len == 0) .unknown else .other;
}

/// Pull `vid_xxxx`, `pid_xxxx` and `mi_xx` out of a device interface path.
///
/// Every HID interface path carries them, so a caller filtering on vendor and
/// product can be answered without opening anything. The authoritative
/// numbers still come from `IOCTL_HID_GET_COLLECTION_INFORMATION`; these are
/// for skipping devices cheaply.
pub const Fields = struct {
    vendor_id: ?u16 = null,
    product_id: ?u16 = null,
    interface_number: ?u8 = null,
};

pub fn parse(path: []const u8) Fields {
    return .{
        .vendor_id = hexAfter(u16, path, "vid_", 4),
        .product_id = hexAfter(u16, path, "pid_", 4),
        .interface_number = hexAfter(u8, path, "&mi_", 2),
    };
}

fn hexAfter(comptime T: type, haystack: []const u8, needle: []const u8, digits: usize) ?T {
    const at = std.ascii.indexOfIgnoreCase(haystack, needle) orelse return null;
    const start = at + needle.len;
    if (start + digits > haystack.len) return null;
    return std.fmt.parseInt(T, haystack[start..][0..digits], 16) catch null;
}

/// `\\?\HID#VID_046D&PID_C52B#7&abc&0&0000#{guid}` becomes
/// `HID\VID_046D&PID_C52B\7&abc&0&0000`.
pub fn instanceId(path: []const u8, buf: []u8) ?[]const u8 {
    const body = if (std.mem.startsWith(u8, path, "\\\\?\\")) path[4..] else path;
    // Drop the interface class GUID, which is the last `#`-separated field.
    const last = std.mem.lastIndexOfScalar(u8, body, '#') orelse return null;
    const id = body[0..last];
    if (id.len > buf.len) return null;
    for (id, 0..) |c, i| buf[i] = if (c == '#') '\\' else c;
    return buf[0..id.len];
}

test "vendor and product come out of an interface path" {
    const path = "\\\\?\\HID#VID_046D&PID_C52B&MI_01&Col01#8&1e78b1e2&0&0000" ++
        "#{4d1e55b2-f16f-11cf-88cb-001111000030}";
    const fields = parse(path);
    try std.testing.expectEqual(@as(?u16, 0x046D), fields.vendor_id);
    try std.testing.expectEqual(@as(?u16, 0xC52B), fields.product_id);
    try std.testing.expectEqual(@as(?u8, 0x01), fields.interface_number);
}

test "a non-composite device has no interface number" {
    const path = "\\\\?\\HID#VID_1209&PID_0001#6&2f9b1c3&0&0000" ++
        "#{4d1e55b2-f16f-11cf-88cb-001111000030}";
    const fields = parse(path);
    try std.testing.expectEqual(@as(?u16, 0x1209), fields.vendor_id);
    try std.testing.expectEqual(@as(?u8, null), fields.interface_number);
}

test "the instance id is recovered from the path without asking Windows" {
    var buf: [512]u8 = undefined;
    const path = "\\\\?\\HID#VID_046D&PID_C52B&MI_01#8&1e78b1e2&0&0000" ++
        "#{4d1e55b2-f16f-11cf-88cb-001111000030}";
    try std.testing.expectEqualStrings(
        "HID\\VID_046D&PID_C52B&MI_01\\8&1e78b1e2&0&0000",
        instanceId(path, &buf).?,
    );
}

test "a parent instance id names the transport" {
    try std.testing.expectEqual(BusType.usb, busTypeFromInstanceId("USB\\VID_046D&PID_C52B\\5&1234"));
    try std.testing.expectEqual(BusType.bluetooth, busTypeFromInstanceId("BTHENUM\\{0000}_LOCALMFG&0000"));
    try std.testing.expectEqual(BusType.bluetooth, busTypeFromInstanceId("BTHLEDEVICE\\{0000}"));
    try std.testing.expectEqual(BusType.i2c, busTypeFromInstanceId("HIDI2C\\VEN_ABC"));
    try std.testing.expectEqual(BusType.virtual, busTypeFromInstanceId("ROOT\\SYSTEM\\0000"));
    // Case is not significant in a device instance ID.
    try std.testing.expectEqual(BusType.usb, busTypeFromInstanceId("usb\\vid_046d"));
    // Something real that has no portable spelling.
    try std.testing.expectEqual(BusType.other, busTypeFromInstanceId("ACPI\\PNP0303"));
    try std.testing.expectEqual(BusType.unknown, busTypeFromInstanceId(""));
}

test {
    std.testing.refAllDecls(@This());
}
