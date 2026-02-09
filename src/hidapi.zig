const std = @import("std");

pub const Device = @import("Device.zig");
pub const DeviceInfo = @import("DeviceInfo.zig");
pub const DeviceInfoIterator = @import("DeviceInfoIterator.zig");

// pub const Errors = InitErrors || ExitErrors;

pub const HID_MAX_DESCRIPTOR_SIZE = 4096;

// pub const InitErrors = error{
//     HidApiInitError,
// };

// pub fn enumerate(vendor_id: c_ushort, product_id_: ?c_ushort) !DeviceInfoIterator {
//     // const product_id = product_id_ orelse 0x0000;
//     // const device_info: ?*c.hid_device_info = c.hid_enumerate(vendor_id, product_id);

//     // return .{
//     //     .start = device_info,
//     //     .current = device_info,
//     // };
// }

// pub fn fromWCharAlloc(alloc: std.mem.Allocator, wide_string: [*c]const c.wchar_t) !?[]u8 {
//     if (wide_string == null) return null;
//     var output: std.ArrayListUnmanaged(u8) = .empty;
//     errdefer output.deinit(alloc);
//     var writer = output.writer(alloc);
//     var index: usize = 0;
//     while (wide_string[index] != 0) : (index += 1) {
//         var buf: [4]u8 = undefined;
//         const len = try std.unicode.utf8Encode(@intCast(wide_string[index]), &buf);
//         try writer.writeAll(buf[0..len]);
//     }
//     return try output.toOwnedSlice(alloc);
// }

// pub fn toWCharAlloc(alloc: std.mem.Allocator, string: []const u8) ![*c]c.wchar_t {
//     var list: std.ArrayList(c.wchar_t) = .empty;
//     errdefer list.deinit(alloc);
//     var iter = (try std.unicode.Utf8View.init(string)).iterator();
//     while (iter.nextCodepoint()) |codepoint| {
//         try list.append(alloc, @intCast(codepoint));
//     }
//     return try list.toOwnedSliceSentinel(alloc, 0);
// }

// pub fn toWChar(string: []const u8, buffer: []c.wchar_t) ![*c]c.wchar_t {
//     var iter = (try std.unicode.Utf8View.init(string)).iterator();
//     var index: usize = 0;
//     while (iter.nextCodepoint()) |codepoint| : (index += 1) {
//         buffer[index] = @intCast(codepoint);
//     }
//     buffer[index] = 0;
//     return buffer.ptr;
// }

test {
    std.testing.refAllDecls(@This());
}
