// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Writing HID report descriptor items.
//!
//! The inverse of `src/descriptor.zig`, and the half of Windows' descriptor
//! reconstruction that is ordinary encoding rather than archaeology: given an
//! item and its value, emit the bytes the USB HID Class Definition 1.11
//! section 6.2.2.2 asks for.
//!
//! Nothing here is Windows-specific -- it is here because Windows is the only
//! backend that has to build a descriptor rather than read one -- and nothing
//! here needs a Windows machine to test.

const std = @import("std");

/// An item's prefix byte with its size bits cleared.
///
/// The low two bits of a prefix say how many data bytes follow, so every
/// value here is a multiple of four and `write` fills those bits in.
pub const Item = enum(u8) {
    main_input = 0x80,
    main_output = 0x90,
    main_feature = 0xB0,
    main_collection = 0xA0,
    main_collection_end = 0xC0,

    global_usage_page = 0x04,
    global_logical_minimum = 0x14,
    global_logical_maximum = 0x24,
    global_physical_minimum = 0x34,
    global_physical_maximum = 0x44,
    global_unit_exponent = 0x54,
    global_unit = 0x64,
    global_report_size = 0x74,
    global_report_id = 0x84,
    global_report_count = 0x94,
    global_push = 0xA4,
    global_pop = 0xB4,

    local_usage = 0x08,
    local_usage_minimum = 0x18,
    local_usage_maximum = 0x28,
    local_designator_index = 0x38,
    local_designator_minimum = 0x48,
    local_designator_maximum = 0x58,
    local_string = 0x78,
    local_string_minimum = 0x88,
    local_string_maximum = 0x98,
    local_delimiter = 0xA8,

    /// Whether this item's data is signed.
    ///
    /// Only the four range items are. Getting this wrong is not a rounding
    /// error: a logical minimum of -1 written unsigned becomes 255, and a
    /// parser reading it back sees a completely different field.
    fn isSigned(self: Item) bool {
        return switch (self) {
            .global_logical_minimum,
            .global_logical_maximum,
            .global_physical_minimum,
            .global_physical_maximum,
            => true,
            else => false,
        };
    }
};

/// Builds a descriptor, counting even when there is nowhere to put it.
///
/// `buf` may be empty, in which case nothing is stored and `len` still ends
/// up as the size the descriptor would have been. That is how
/// `getReportDescriptorLen` answers without a buffer: the reconstruction is
/// run twice, once to measure and once to fill.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    /// The descriptor written so far, or `error.BufferTooSmall` if it did not
    /// fit. Checked here rather than at each byte so that a measuring pass
    /// can run to completion.
    pub fn finish(self: *const Writer) error{BufferTooSmall}![]const u8 {
        if (self.len > self.buf.len) return error.BufferTooSmall;
        return self.buf[0..self.len];
    }

    fn byte(self: *Writer, b: u8) void {
        if (self.len < self.buf.len) self.buf[self.len] = b;
        self.len += 1;
    }

    /// Write one short item.
    ///
    /// The data is emitted in the narrowest of one, two or four bytes that
    /// holds it -- never three, which the size field cannot express -- and
    /// little endian.
    pub fn write(self: *Writer, item: Item, data: i64) error{ValueTooWide}!void {
        if (item == .main_collection_end) {
            // The only item that carries no data at all.
            self.byte(@intFromEnum(item));
            return;
        }

        // Nested ranges, so this is a chain of comparisons rather than a
        // switch: a switch wants its ranges disjoint, and every narrower one
        // here sits inside the next.
        const width: u8 = if (item.isSigned()) blk: {
            if (data >= -128 and data <= 127) break :blk 1;
            if (data >= -32768 and data <= 32767) break :blk 2;
            if (data >= -2147483648 and data <= 2147483647) break :blk 4;
            return error.ValueTooWide;
        } else blk: {
            if (data < 0) return error.ValueTooWide;
            if (data <= 0xFF) break :blk 1;
            if (data <= 0xFFFF) break :blk 2;
            if (data <= 0xFFFF_FFFF) break :blk 4;
            return error.ValueTooWide;
        };

        // 1, 2 and 4 data bytes are encoded as 1, 2 and 3.
        self.byte(@intFromEnum(item) + if (width == 4) @as(u8, 3) else width);
        const bits: u32 = @truncate(@as(u64, @bitCast(data)));
        for (0..width) |i| self.byte(@truncate(bits >> @intCast(i * 8)));
    }
};

test "an item with no data is one byte" {
    var buf: [8]u8 = undefined;
    var w: Writer = .init(&buf);
    try w.write(.main_collection_end, 0);
    try std.testing.expectEqualSlices(u8, &.{0xC0}, try w.finish());
}

test "unsigned data takes the narrowest width that holds it" {
    var buf: [16]u8 = undefined;

    {
        var w: Writer = .init(&buf);
        try w.write(.global_usage_page, 0x01);
        try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x01 }, try w.finish());
    }
    {
        var w: Writer = .init(&buf);
        try w.write(.global_usage_page, 0xFF00);
        try std.testing.expectEqualSlices(u8, &.{ 0x06, 0x00, 0xFF }, try w.finish());
    }
    {
        // Four data bytes, encoded as a size of 3. Writing 3 there instead
        // would name a size the specification does not have.
        var w: Writer = .init(&buf);
        try w.write(.local_usage, 0x0001_0002);
        try std.testing.expectEqualSlices(u8, &.{ 0x0B, 0x02, 0x00, 0x01, 0x00 }, try w.finish());
    }
}

test "the range items are signed and the rest are not" {
    var buf: [16]u8 = undefined;

    {
        // Logical Minimum (-1): one byte of 0xFF.
        var w: Writer = .init(&buf);
        try w.write(.global_logical_minimum, -1);
        try std.testing.expectEqualSlices(u8, &.{ 0x15, 0xFF }, try w.finish());
    }
    {
        // Logical Maximum (255) has to widen to two bytes, because as a
        // signed value one byte only reaches 127. A device declaring a byte
        // field is the commonest thing there is, so getting this wrong would
        // be wrong nearly everywhere.
        var w: Writer = .init(&buf);
        try w.write(.global_logical_maximum, 255);
        try std.testing.expectEqualSlices(u8, &.{ 0x26, 0xFF, 0x00 }, try w.finish());
    }
    {
        // Report Count is unsigned, so 255 stays in one byte.
        var w: Writer = .init(&buf);
        try w.write(.global_report_count, 255);
        try std.testing.expectEqualSlices(u8, &.{ 0x95, 0xFF }, try w.finish());
    }
    {
        var w: Writer = .init(&buf);
        try w.write(.global_logical_minimum, -32768);
        try std.testing.expectEqualSlices(u8, &.{ 0x16, 0x00, 0x80 }, try w.finish());
    }
}

test "a value too wide to encode is refused" {
    var buf: [16]u8 = undefined;
    var w: Writer = .init(&buf);
    try std.testing.expectError(error.ValueTooWide, w.write(.global_report_count, -1));
    try std.testing.expectError(
        error.ValueTooWide,
        w.write(.global_logical_minimum, -2147483649),
    );
}

test "an empty buffer measures without writing" {
    var w: Writer = .init(&.{});
    try w.write(.global_usage_page, 0x01);
    try w.write(.local_usage, 0x02);
    try w.write(.main_collection, 0x01);
    try w.write(.main_collection_end, 0);
    // 2 + 2 + 2 + 1
    try std.testing.expectEqual(@as(usize, 7), w.len);
    try std.testing.expectError(error.BufferTooSmall, w.finish());
}

test "a buffer one byte short is reported rather than truncated" {
    var buf: [6]u8 = undefined;
    var w: Writer = .init(&buf);
    try w.write(.global_usage_page, 0x01);
    try w.write(.local_usage, 0x02);
    try w.write(.main_collection, 0x01);
    try w.write(.main_collection_end, 0);
    try std.testing.expectError(error.BufferTooSmall, w.finish());
}

test "what it writes, the descriptor walker reads back" {
    // The two halves of this library's understanding of a descriptor, checked
    // against each other: a mouse collection written here is a mouse
    // collection when parsed.
    const descriptor = @import("../../descriptor.zig");

    var buf: [32]u8 = undefined;
    var w: Writer = .init(&buf);
    try w.write(.global_usage_page, 0x01);
    try w.write(.local_usage, 0x02);
    try w.write(.main_collection, 0x01);
    try w.write(.main_collection_end, 0);

    const usage = descriptor.firstUsage(try w.finish()).?;
    try std.testing.expectEqual(@as(u16, 0x01), usage.page);
    try std.testing.expectEqual(@as(u16, 0x02), usage.id);
}

test {
    std.testing.refAllDecls(@This());
}
