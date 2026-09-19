// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Just enough of a HID report descriptor parser to answer what a device is
//! for.
//!
//! Enumeration wants the usage page and usage of the first top-level
//! collection, because that is how a caller tells a keyboard from a mouse from
//! a vendor-defined device without opening any of them. Linux, FreeBSD and
//! macOS all hand over the raw descriptor, so all three come through here.
//! Windows does not, and gets the same pair from its own parsed form instead.
//!
//! This is not a general parser and does not try to be: it does not track
//! report sizes, it does not build a report layout, and it stops at the first
//! collection it finds. See the HID Class Definition 1.11, section 6.2.2, for
//! the item encoding it implements.

const std = @import("std");

/// The usage page and usage of a device's first top-level collection.
pub const Usage = struct {
    page: u16,
    id: u16,
};

/// The item type in bits 3..2 of an item's prefix byte.
const Type = enum(u2) { main = 0, global = 1, local = 2, reserved = 3 };

/// The prefix of a long item, which carries its own size byte. Long items are
/// defined by the specification and used by nothing, but a descriptor
/// containing one still has to be walked past rather than misread.
const long_item_prefix = 0b1111_1110;

/// Find the usage page and usage of the first top-level collection in
/// `bytes`, or `null` if the descriptor declares none.
///
/// Never fails: a truncated or malformed descriptor stops the walk and yields
/// whatever was found before it, on the grounds that a device answering
/// nonsense is a device to report rather than one to refuse to list. The
/// caller sees `null`, the same as for a descriptor that genuinely has no
/// collection.
pub fn firstUsage(bytes: []const u8) ?Usage {
    var page: u16 = 0;
    var usage: ?u16 = null;
    // A usage item may carry the page in its own top 16 bits, in which case it
    // wins over the global page for that one usage.
    var usage_page_from_item: ?u16 = null;

    var i: usize = 0;
    while (i < bytes.len) {
        const prefix = bytes[i];

        if (prefix == long_item_prefix) {
            // bDataSize, bLongItemTag, then the data.
            if (i + 2 >= bytes.len) return null;
            const data_size = bytes[i + 1];
            i += 3 + data_size;
            continue;
        }

        const size: usize = switch (@as(u2, @truncate(prefix))) {
            0 => 0,
            1 => 1,
            2 => 2,
            // A `bSize` of 3 means four bytes, not three. Reading it as three
            // is the classic way to get a descriptor parser subtly wrong.
            3 => 4,
        };
        const item_type: Type = @enumFromInt(@as(u2, @truncate(prefix >> 2)));
        const tag: u4 = @truncate(prefix >> 4);

        const data_start = i + 1;
        if (data_start + size > bytes.len) return null;
        const data = bytes[data_start..][0..size];

        switch (item_type) {
            .global => if (tag == 0x0) { // Usage Page
                page = @truncate(readValue(data));
            },
            .local => if (tag == 0x0) { // Usage
                const v = readValue(data);
                if (size == 4) {
                    // An extended usage: page in the high half, usage in the
                    // low half.
                    usage_page_from_item = @truncate(v >> 16);
                    usage = @truncate(v);
                } else {
                    usage_page_from_item = null;
                    usage = @truncate(v);
                }
            },
            .main => if (tag == 0xA) { // Collection
                return .{
                    .page = usage_page_from_item orelse page,
                    .id = usage orelse return null,
                };
            },
            .reserved => {},
        }

        i = data_start + size;
    }
    return null;
}

/// An item's data, which is little endian and 0, 1, 2 or 4 bytes wide.
///
/// Read unsigned throughout. The specification calls some item data signed,
/// but none of the items this walker looks at is one of them.
fn readValue(data: []const u8) u32 {
    var v: u32 = 0;
    for (data, 0..) |b, shift| v |= @as(u32, b) << @intCast(shift * 8);
    return v;
}

test "a mouse descriptor reports the generic desktop mouse usage" {
    // Usage Page (Generic Desktop), Usage (Mouse), Collection (Application)
    const bytes = [_]u8{ 0x05, 0x01, 0x09, 0x02, 0xA1, 0x01 };
    const u = firstUsage(&bytes).?;
    try std.testing.expectEqual(@as(u16, 0x01), u.page);
    try std.testing.expectEqual(@as(u16, 0x02), u.id);
}

test "a vendor-defined page above 0xff is kept whole" {
    // Usage Page (0xFF00), Usage (0x01), Collection (Application). The page
    // needs both data bytes; truncating to one would report 0x00.
    const bytes = [_]u8{ 0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01 };
    const u = firstUsage(&bytes).?;
    try std.testing.expectEqual(@as(u16, 0xFF00), u.page);
    try std.testing.expectEqual(@as(u16, 0x01), u.id);
}

test "an extended usage carries its own page" {
    // Usage Page (Generic Desktop) then a four byte Usage naming page 0xFF01
    // and usage 0x0002, which wins over the global page.
    const bytes = [_]u8{ 0x05, 0x01, 0x0B, 0x02, 0x00, 0x01, 0xFF, 0xA1, 0x01 };
    const u = firstUsage(&bytes).?;
    try std.testing.expectEqual(@as(u16, 0xFF01), u.page);
    try std.testing.expectEqual(@as(u16, 0x0002), u.id);
}

test "bSize of 3 means four bytes" {
    // If the four byte usage above were read as three, the collection item
    // would be found one byte early and the walk would go wrong. Prove the
    // width table directly.
    const bytes = [_]u8{ 0x05, 0x01, 0x09, 0x06, 0xA1, 0x01 };
    const u = firstUsage(&bytes).?;
    try std.testing.expectEqual(@as(u16, 0x06), u.id); // Keyboard
}

test "a long item is stepped over rather than misread" {
    // A long item with two data bytes, then a perfectly ordinary keyboard
    // descriptor. Getting the skip wrong finds no collection at all.
    const bytes = [_]u8{
        0xFE, 0x02, 0x00, 0xAA, 0xBB,
        0x05, 0x01, 0x09, 0x06, 0xA1,
        0x01,
    };
    const u = firstUsage(&bytes).?;
    try std.testing.expectEqual(@as(u16, 0x01), u.page);
    try std.testing.expectEqual(@as(u16, 0x06), u.id);
}

test "a truncated descriptor yields null rather than reading past the end" {
    // A Usage Page item that promises two bytes and supplies one.
    try std.testing.expectEqual(@as(?Usage, null), firstUsage(&[_]u8{ 0x06, 0x00 }));
    // A collection with no usage before it.
    try std.testing.expectEqual(@as(?Usage, null), firstUsage(&[_]u8{ 0xA1, 0x01 }));
    // Nothing at all.
    try std.testing.expectEqual(@as(?Usage, null), firstUsage(&.{}));
}

test {
    std.testing.refAllDecls(@This());
}
