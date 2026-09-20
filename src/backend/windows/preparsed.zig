// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The layout of Windows' `HIDP_PREPARSED_DATA`.
//!
//! This is the structure the HID class driver builds from a device's report
//! descriptor and hands back from `IOCTL_HID_GET_COLLECTION_DESCRIPTOR`. It is
//! **undocumented**: Microsoft's position is that it is opaque and that
//! `HidP_*` is the way to read it. The reason for opening it anyway is that
//! the documented calls do not expose where each field sits inside a report --
//! `HIDP_VALUE_CAPS` has a bit *size* and no bit *position* -- and without
//! that a reconstructed descriptor cannot put fields in the right order or
//! account for padding. The C hidapi came to the same conclusion and reads the
//! same fields.
//!
//! Two things keep that honest. The blob begins with the eight bytes
//! `HidP KDR`, which is checked before anything else is believed, so a Windows
//! that changes the format is met with `error.Unsupported` rather than with
//! nonsense. And the layout below is pinned by `comptime` assertions on every
//! offset, so that a mistake *here* is a failed build rather than a garbled
//! descriptor on a machine none of us is sitting at.
//!
//! Fields this library does not read are still declared, because their sizes
//! are what place the ones it does.

const std = @import("std");

/// What the blob starts with, if it is one.
pub const magic = "HidP KDR";

/// `hid_pp_caps_info`: where one report type's capabilities live.
pub const CapsInfo = extern struct {
    first_cap: u16,
    number_of_caps: u16,
    last_cap: u16,
    report_byte_length: u16,

    comptime {
        std.debug.assert(@sizeOf(CapsInfo) == 8);
    }
};

/// `hid_pp_link_collection_node`: one node of the collection tree.
pub const LinkCollectionNode = extern struct {
    link_usage: u16,
    link_usage_page: u16,
    parent: u16,
    number_of_children: u16,
    next_sibling: u16,
    first_child: u16,
    /// `CollectionType:8`, `IsAlias:1`, `Reserved:23`, packed into one
    /// `ULONG`.
    bits: u32,

    pub fn collectionType(self: LinkCollectionNode) u8 {
        return @truncate(self.bits);
    }

    pub fn isAlias(self: LinkCollectionNode) bool {
        return (self.bits >> 8) & 1 != 0;
    }

    comptime {
        std.debug.assert(@sizeOf(LinkCollectionNode) == 16);
        std.debug.assert(@offsetOf(LinkCollectionNode, "bits") == 12);
    }
};

/// `hidp_unknown_token`: a global item the parser kept but did not interpret.
pub const UnknownToken = extern struct {
    token: u8,
    reserved: [3]u8,
    bit_field: u32,

    comptime {
        std.debug.assert(@sizeOf(UnknownToken) == 8);
    }
};

/// `hid_pp_cap`: one field of one report.
///
/// The two unions at the end are the awkward part. Which arm is live depends
/// on `is_range` for the first and `is_button_cap` for the second, and the
/// arms are different sizes, so the whole structure's size comes from the
/// larger of each.
pub const Cap = extern struct {
    usage_page: u16,
    report_id: u8,
    bit_position: u8,
    /// Called `BitSize` by the documented API.
    report_size: u16,
    report_count: u16,
    byte_position: u16,
    bit_count: u16,
    bit_field: u32,
    next_byte_position: u16,
    link_collection: u16,
    link_usage_page: u16,
    link_usage: u16,

    /// Eight one-bit flags in one byte, in declaration order from the low
    /// bit: `IsMultipleItemsForArray`, `IsPadding`, `IsButtonCap`,
    /// `IsAbsolute`, `IsRange`, `IsAlias`, `IsStringRange`,
    /// `IsDesignatorRange`.
    flags: u8,
    reserved1: [3]u8,

    unknown_tokens: [4]UnknownToken,

    /// `Range` when `isRange()`, `NotRange` otherwise. Both are eight
    /// `USHORT`s, so the union's size is not in doubt -- only which names to
    /// read it by.
    usage: extern union {
        range: extern struct {
            usage_min: u16,
            usage_max: u16,
            string_min: u16,
            string_max: u16,
            designator_min: u16,
            designator_max: u16,
            data_index_min: u16,
            data_index_max: u16,
        },
        not_range: extern struct {
            usage: u16,
            reserved1: u16,
            string_index: u16,
            reserved2: u16,
            designator_index: u16,
            reserved3: u16,
            data_index: u16,
            reserved4: u16,
        },
    },

    /// `Button` when `isButtonCap()`, `NotButton` otherwise. These *are*
    /// different sizes -- eight bytes against twenty -- so the union is as
    /// big as the second.
    range: extern union {
        button: extern struct {
            logical_min: i32,
            logical_max: i32,
        },
        not_button: extern struct {
            has_null: u8,
            reserved4: [3]u8,
            logical_min: i32,
            logical_max: i32,
            physical_min: i32,
            physical_max: i32,
        },
    },

    units: u32,
    units_exp: u32,

    pub fn isMultipleItemsForArray(self: Cap) bool {
        return self.flags & (1 << 0) != 0;
    }
    pub fn isPadding(self: Cap) bool {
        return self.flags & (1 << 1) != 0;
    }
    pub fn isButtonCap(self: Cap) bool {
        return self.flags & (1 << 2) != 0;
    }
    pub fn isAbsolute(self: Cap) bool {
        return self.flags & (1 << 3) != 0;
    }
    pub fn isRange(self: Cap) bool {
        return self.flags & (1 << 4) != 0;
    }
    pub fn isAlias(self: Cap) bool {
        return self.flags & (1 << 5) != 0;
    }
    pub fn isStringRange(self: Cap) bool {
        return self.flags & (1 << 6) != 0;
    }
    pub fn isDesignatorRange(self: Cap) bool {
        return self.flags & (1 << 7) != 0;
    }

    /// The logical minimum, from whichever arm of the second union is live.
    pub fn logicalMin(self: Cap) i32 {
        return if (self.isButtonCap()) self.range.button.logical_min else self.range.not_button.logical_min;
    }

    pub fn logicalMax(self: Cap) i32 {
        return if (self.isButtonCap()) self.range.button.logical_max else self.range.not_button.logical_max;
    }

    comptime {
        // Every offset, because the whole file is only trustworthy if these
        // are. Worked out from the C declaration in hidapi's
        // `hidapi_descriptor_reconstruct.h`.
        std.debug.assert(@offsetOf(Cap, "usage_page") == 0);
        std.debug.assert(@offsetOf(Cap, "report_id") == 2);
        std.debug.assert(@offsetOf(Cap, "bit_position") == 3);
        std.debug.assert(@offsetOf(Cap, "report_size") == 4);
        std.debug.assert(@offsetOf(Cap, "report_count") == 6);
        std.debug.assert(@offsetOf(Cap, "byte_position") == 8);
        std.debug.assert(@offsetOf(Cap, "bit_count") == 10);
        std.debug.assert(@offsetOf(Cap, "bit_field") == 12);
        std.debug.assert(@offsetOf(Cap, "next_byte_position") == 16);
        std.debug.assert(@offsetOf(Cap, "link_collection") == 18);
        std.debug.assert(@offsetOf(Cap, "link_usage_page") == 20);
        std.debug.assert(@offsetOf(Cap, "link_usage") == 22);
        std.debug.assert(@offsetOf(Cap, "flags") == 24);
        std.debug.assert(@offsetOf(Cap, "unknown_tokens") == 28);
        std.debug.assert(@offsetOf(Cap, "usage") == 60);
        std.debug.assert(@offsetOf(Cap, "range") == 76);
        std.debug.assert(@offsetOf(Cap, "units") == 96);
        std.debug.assert(@offsetOf(Cap, "units_exp") == 100);
        std.debug.assert(@sizeOf(Cap) == 104);
    }
};

/// The fixed head of the blob. The capabilities and the collection tree
/// follow it, and are reached through `caps` and `linkCollectionNodes`.
pub const Header = extern struct {
    magic_key: [8]u8,
    usage: u16,
    usage_page: u16,
    reserved: [2]u16,
    /// Indexed by report type: input, output, feature.
    caps_info: [3]CapsInfo,
    /// Counted from the start of the capability array, not from the start of
    /// the blob.
    first_byte_of_link_collection_array: u16,
    number_link_collection_nodes: u16,

    comptime {
        std.debug.assert(@offsetOf(Header, "caps_info") == 16);
        std.debug.assert(@offsetOf(Header, "first_byte_of_link_collection_array") == 40);
        std.debug.assert(@offsetOf(Header, "number_link_collection_nodes") == 42);
        std.debug.assert(@sizeOf(Header) == 44);
    }
};

/// Where the capability array begins, which is immediately after the header.
const caps_offset = @sizeOf(Header);

/// A blob that has been checked far enough to read.
pub const PreparsedData = struct {
    bytes: []const u8,
    header: *const Header,

    pub const Error = error{Unsupported};

    /// Check the magic and the bounds, and return something that can be read.
    ///
    /// `error.Unsupported` for anything that is not recognisably one of these,
    /// which is the same answer the rest of the library gives for a
    /// descriptor Windows will not produce -- because that is what it means.
    pub fn init(bytes: []const u8) Error!PreparsedData {
        if (bytes.len < @sizeOf(Header)) return error.Unsupported;
        const header: *const Header = @ptrCast(@alignCast(bytes.ptr));
        if (!std.mem.eql(u8, &header.magic_key, magic)) return error.Unsupported;

        const self: PreparsedData = .{ .bytes = bytes, .header = header };
        // The arrays have to be inside the blob before anything indexes them.
        for (0..3) |report_type| {
            const info = header.caps_info[report_type];
            if (info.number_of_caps == 0) continue;
            const end = caps_offset +
                (@as(usize, info.first_cap) + info.number_of_caps) * @sizeOf(Cap);
            if (end > bytes.len) return error.Unsupported;
        }
        const nodes_end = caps_offset +
            @as(usize, header.first_byte_of_link_collection_array) +
            @as(usize, header.number_link_collection_nodes) * @sizeOf(LinkCollectionNode);
        if (nodes_end > bytes.len) return error.Unsupported;

        return self;
    }

    /// The capabilities of one report type.
    pub fn caps(self: PreparsedData, report_type: usize) []const Cap {
        const info = self.header.caps_info[report_type];
        if (info.number_of_caps == 0) return &.{};
        const start = caps_offset + @as(usize, info.first_cap) * @sizeOf(Cap);
        const ptr: [*]const Cap = @ptrCast(@alignCast(self.bytes.ptr + start));
        return ptr[0..info.number_of_caps];
    }

    /// The whole capability array, across all three report types.
    ///
    /// They live contiguously and `caps_info[rt].first_cap` indexes into this
    /// rather than into a per-type array, so anything holding an index out of
    /// the blob needs the whole thing.
    pub fn allCaps(self: PreparsedData) []const Cap {
        var count: usize = 0;
        for (self.header.caps_info) |info| {
            count = @max(count, @as(usize, info.first_cap) + info.number_of_caps);
        }
        if (count == 0) return &.{};
        const ptr: [*]const Cap = @ptrCast(@alignCast(self.bytes.ptr + caps_offset));
        return ptr[0..count];
    }

    /// The collection tree.
    ///
    /// Note the offset is counted from the capability array rather than from
    /// the start of the blob, which is the one place this layout is
    /// genuinely surprising.
    pub fn linkCollectionNodes(self: PreparsedData) []const LinkCollectionNode {
        const count = self.header.number_link_collection_nodes;
        if (count == 0) return &.{};
        const start = caps_offset + @as(usize, self.header.first_byte_of_link_collection_array);
        const ptr: [*]const LinkCollectionNode = @ptrCast(@alignCast(self.bytes.ptr + start));
        return ptr[0..count];
    }
};

test "a blob that is not one is refused rather than read" {
    try std.testing.expectError(error.Unsupported, PreparsedData.init(&.{}));
    try std.testing.expectError(error.Unsupported, PreparsedData.init("short"));

    var wrong: [64]u8 align(4) = @splat(0);
    @memcpy(wrong[0..8], "NotHidP!");
    try std.testing.expectError(error.Unsupported, PreparsedData.init(&wrong));
}

test "a well formed empty blob reads as empty" {
    var bytes: [@sizeOf(Header)]u8 align(4) = @splat(0);
    const header: *Header = @ptrCast(&bytes);
    @memcpy(&header.magic_key, magic);
    header.usage = 0x02;
    header.usage_page = 0x01;

    const pp = try PreparsedData.init(&bytes);
    try std.testing.expectEqual(@as(u16, 0x01), pp.header.usage_page);
    try std.testing.expectEqual(@as(u16, 0x02), pp.header.usage);
    try std.testing.expectEqual(@as(usize, 0), pp.caps(0).len);
    try std.testing.expectEqual(@as(usize, 0), pp.linkCollectionNodes().len);
}

test "the report lengths come out of the header" {
    // What `Device.readCaps` reads, and the reason it no longer goes through
    // `HidD_GetPreparsedData`: these are here, in a blob a zero-access handle
    // can fetch.
    var bytes: [@sizeOf(Header)]u8 align(4) = @splat(0);
    const header: *Header = @ptrCast(&bytes);
    @memcpy(&header.magic_key, magic);
    header.caps_info[0].report_byte_length = 9; // input
    header.caps_info[1].report_byte_length = 2; // output
    header.caps_info[2].report_byte_length = 33; // feature

    const pp = try PreparsedData.init(&bytes);
    try std.testing.expectEqual(@as(u16, 9), pp.header.caps_info[0].report_byte_length);
    try std.testing.expectEqual(@as(u16, 2), pp.header.caps_info[1].report_byte_length);
    try std.testing.expectEqual(@as(u16, 33), pp.header.caps_info[2].report_byte_length);
}

test "an array that runs past the end of the blob is refused" {
    var bytes: [@sizeOf(Header)]u8 align(4) = @splat(0);
    const header: *Header = @ptrCast(&bytes);
    @memcpy(&header.magic_key, magic);
    // One input capability, which does not fit: the header is all there is.
    header.caps_info[0] = .{
        .first_cap = 0,
        .number_of_caps = 1,
        .last_cap = 1,
        .report_byte_length = 8,
    };
    try std.testing.expectError(error.Unsupported, PreparsedData.init(&bytes));
}

test "the flag bits are read in declaration order" {
    var cap: Cap = std.mem.zeroes(Cap);
    cap.flags = 0b0001_0100; // IsRange and IsButtonCap
    try std.testing.expect(cap.isButtonCap());
    try std.testing.expect(cap.isRange());
    try std.testing.expect(!cap.isPadding());
    try std.testing.expect(!cap.isAlias());

    cap.flags = 0b0000_0010; // IsPadding
    try std.testing.expect(cap.isPadding());
    try std.testing.expect(!cap.isButtonCap());
}

test "the logical range comes from whichever union arm is live" {
    var cap: Cap = std.mem.zeroes(Cap);

    cap.flags = 1 << 2; // IsButtonCap
    cap.range.button = .{ .logical_min = -3, .logical_max = 7 };
    try std.testing.expectEqual(@as(i32, -3), cap.logicalMin());
    try std.testing.expectEqual(@as(i32, 7), cap.logicalMax());

    cap = std.mem.zeroes(Cap);
    cap.range.not_button = .{
        .has_null = 0,
        .reserved4 = @splat(0),
        .logical_min = -1,
        .logical_max = 255,
        .physical_min = 0,
        .physical_max = 0,
    };
    try std.testing.expectEqual(@as(i32, -1), cap.logicalMin());
    try std.testing.expectEqual(@as(i32, 255), cap.logicalMax());
}

test {
    std.testing.refAllDecls(@This());
}
