// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reading a HID report descriptor.
//!
//! A descriptor is a byte string describing what a device's reports contain:
//! how many, how long, which bits mean what, and what range each field
//! carries. Without it a report is eight opaque bytes. With it, byte 3 is the
//! wheel and it counts from -127 to 127.
//!
//! There are three levels here, and a caller can stop at whichever answers
//! the question:
//!
//! * `firstUsage` says what the device is -- a keyboard, a mouse, something
//!   vendor defined -- and is what enumeration uses to fill in
//!   `DeviceInfo.usage_page` and `usage`.
//! * `Iterator` walks the raw items, for code that wants the descriptor
//!   exactly as written.
//! * `Parser` runs the item state machine and yields a `Field` per main item,
//!   with its bit position, its size, its usages and its ranges all resolved.
//!   `Field.extract` then reads one out of a report.
//!
//! Nothing here allocates. `Parser` is a value the caller owns, about two
//! kilobytes, and the slices a `Field` hands back point into it and stay valid
//! until the next call to `next` -- the same rule `Enumerator` follows.
//!
//! The item encoding is the USB HID Class Definition 1.11, section 6.2.2.

const std = @import("std");

/// The usage page and usage of a device's first top-level collection.
pub const Usage = struct {
    page: u16,
    id: u16,
};

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
///
/// This is the cheap question -- what *is* this device -- and needs none of
/// `Parser`'s state. Enumeration asks it for every device it finds.
pub fn firstUsage(bytes: []const u8) ?Usage {
    var page: u16 = 0;
    var usage: ?u16 = null;
    // A usage item may carry the page in its own top 16 bits, in which case
    // it wins over the global page for that one usage.
    var usage_page_from_item: ?u16 = null;

    var it: Iterator = .init(bytes);
    while (it.next()) |raw| {
        switch (raw.type) {
            .global => if (raw.tag == global_tag.usage_page) {
                page = @truncate(raw.unsigned());
            },
            .local => if (raw.tag == local_tag.usage) {
                const v = raw.unsigned();
                if (raw.data.len == 4) {
                    usage_page_from_item = @truncate(v >> 16);
                    usage = @truncate(v);
                } else {
                    usage_page_from_item = null;
                    usage = @truncate(v);
                }
            },
            .main => if (raw.tag == main_tag.collection) {
                return .{
                    .page = usage_page_from_item orelse page,
                    .id = usage orelse return null,
                };
            },
            .reserved => {},
        }
    }
    return null;
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

// ---------------------------------------------------------------------------
// Raw items
// ---------------------------------------------------------------------------

/// One item as the descriptor wrote it.
pub const RawItem = struct {
    type: Type,
    /// The item's tag, in the top four bits of the prefix.
    tag: u4,
    /// The data bytes, 0, 1, 2 or 4 of them, little endian. Empty for a long
    /// item, whose payload is in `long_data`.
    data: []const u8,
    /// A long item's payload. Long items are defined by the specification and
    /// used by nothing, but one has to be walked past rather than misread.
    long_data: []const u8 = &.{},

    pub const Type = enum(u2) { main = 0, global = 1, local = 2, reserved = 3 };

    /// The data as an unsigned value.
    pub fn unsigned(self: RawItem) u32 {
        var v: u32 = 0;
        for (self.data, 0..) |b, i| v |= @as(u32, b) << @intCast(i * 8);
        return v;
    }

    /// The data as a signed value, sign-extended from its width.
    ///
    /// Which items are signed is not a property of the encoding -- the same
    /// two bytes are a logical minimum of -1 or a report count of 65535
    /// depending only on which item they belong to -- so this is applied by
    /// the caller and never inferred here.
    pub fn signed(self: RawItem) i32 {
        const raw = self.unsigned();
        return switch (self.data.len) {
            0 => 0,
            1 => @as(i8, @bitCast(@as(u8, @truncate(raw)))),
            2 => @as(i16, @bitCast(@as(u16, @truncate(raw)))),
            else => @bitCast(raw),
        };
    }
};

/// Walks the items of a descriptor.
///
/// Stops at the first malformed item rather than guessing, because a
/// descriptor that is wrong about its own lengths says nothing reliable about
/// what follows.
pub const Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Iterator) ?RawItem {
        if (self.index >= self.bytes.len) return null;
        const prefix = self.bytes[self.index];

        if (prefix == long_item_prefix) {
            if (self.index + 2 >= self.bytes.len) return null;
            const size = self.bytes[self.index + 1];
            const tag: u4 = @truncate(self.bytes[self.index + 2]);
            const start = self.index + 3;
            if (start + size > self.bytes.len) return null;
            self.index = start + size;
            return .{
                .type = .reserved,
                .tag = tag,
                .data = &.{},
                .long_data = self.bytes[start..][0..size],
            };
        }

        // A `bSize` of 3 means four bytes, not three. Reading it as three is
        // the classic way to get a descriptor parser subtly wrong.
        const size: usize = switch (@as(u2, @truncate(prefix))) {
            0 => 0,
            1 => 1,
            2 => 2,
            3 => 4,
        };
        const start = self.index + 1;
        if (start + size > self.bytes.len) return null;
        self.index = start + size;
        return .{
            .type = @enumFromInt(@as(u2, @truncate(prefix >> 2))),
            .tag = @truncate(prefix >> 4),
            .data = self.bytes[start..][0..size],
        };
    }
};

// ---------------------------------------------------------------------------
// Parsed fields
// ---------------------------------------------------------------------------

/// Which report a field belongs to.
pub const Kind = enum(u2) {
    input = 0,
    output = 1,
    feature = 2,

    pub fn format(self: Kind, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(@tagName(self));
    }
};

/// What kind of collection a `Collection` is, from the main item's data.
pub const CollectionType = enum(u8) {
    physical = 0x00,
    application = 0x01,
    logical = 0x02,
    report = 0x03,
    named_array = 0x04,
    usage_switch = 0x05,
    usage_modifier = 0x06,
    _,
};

/// One level of the collection a field sits inside.
pub const Collection = struct {
    type: CollectionType,
    usage_page: u16,
    usage: u16,
};

/// The data bits of a main item, as the specification names them.
///
/// `constant` and `variable` are the two that change how a field is read at
/// all: a constant field is padding, and an array field holds indices into
/// its usage range where a variable one holds a value per usage.
pub const Flags = packed struct(u32) {
    constant: bool = false,
    variable: bool = false,
    relative: bool = false,
    wrap: bool = false,
    non_linear: bool = false,
    no_preferred_state: bool = false,
    null_state: bool = false,
    @"volatile": bool = false,
    buffered_bytes: bool = false,
    _reserved: u23 = 0,

    pub fn format(self: Flags, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(if (self.constant) "Cnst" else "Data");
        try w.writeAll(if (self.variable) ",Var" else ",Ary");
        try w.writeAll(if (self.relative) ",Rel" else ",Abs");
        if (self.wrap) try w.writeAll(",Wrap");
        if (self.non_linear) try w.writeAll(",NonLin");
        if (self.no_preferred_state) try w.writeAll(",NoPref");
        if (self.null_state) try w.writeAll(",Null");
        if (self.@"volatile") try w.writeAll(",Vol");
        if (self.buffered_bytes) try w.writeAll(",Buff");
    }
};

/// How a main item names its usages.
pub const Usages = union(enum) {
    /// None were declared, which is legal and usual for padding.
    none,
    /// `Usage Minimum` through `Usage Maximum`.
    range: struct { min: u32, max: u32 },
    /// Individually listed, as extended usages -- page in the high sixteen
    /// bits. Points into the parser and is valid until its next `next`.
    list: []const u32,
};

/// One main item: a run of `count` fields of `bit_size` bits each.
///
/// A main item is kept whole rather than expanded into one `Field` per
/// element, because that is how the descriptor says it and because for an
/// array the elements are not separate things at all -- they are slots, and
/// the usages describe the values that may appear in them rather than what
/// each slot means. `usageAt` resolves the per-element usage where that is a
/// meaningful question.
pub const Field = struct {
    report_id: u8,
    kind: Kind,
    /// Where element zero starts, in bits from the beginning of the report
    /// **body** -- that is, after the report ID byte if the device uses them.
    bit_offset: u32,
    bit_size: u16,
    count: u16,

    /// The usage page in force, which the usages in `usages` fall under
    /// unless one carries its own page in its high bits.
    usage_page: u16,
    usages: Usages,

    logical_min: i32,
    logical_max: i32,
    physical_min: i32,
    physical_max: i32,
    unit: u32,
    unit_exponent: i32,

    flags: Flags,

    /// The collections enclosing this field, outermost first. Points into the
    /// parser and is valid until its next `next`.
    collections: []const Collection,

    /// How many bits the whole item occupies.
    pub fn totalBits(self: Field) u32 {
        return @as(u32, self.bit_size) * self.count;
    }

    /// The usage of element `index`, or `null` when the question does not
    /// apply.
    ///
    /// It does not apply to an array, where a slot holds an index rather than
    /// meaning something on its own, nor to an item that declared no usages.
    /// For a variable item the specification says usage *i* belongs to
    /// element *i*, and that the last usage repeats for any elements beyond
    /// the list -- which is how one `Usage` and a count of eight describes
    /// eight identical things.
    pub fn usageAt(self: Field, index: u16) ?u32 {
        if (!self.flags.variable) return null;
        if (index >= self.count) return null;
        return switch (self.usages) {
            .none => null,
            .range => |r| blk: {
                const v = r.min + index;
                break :blk if (v > r.max) r.max else v;
            },
            .list => |list| blk: {
                if (list.len == 0) break :blk null;
                break :blk if (index < list.len) list[index] else list[list.len - 1];
            },
        };
    }

    /// Read element `index` out of a report body.
    ///
    /// `body` is the report **without** any leading report ID byte: on a
    /// device that uses report IDs, pass `report[1..]`. Returns `null` when
    /// the field does not fit in what was given, which is what a short report
    /// looks like.
    ///
    /// The value is sign-extended when the field's logical minimum is
    /// negative, because that is the only thing that says a field is signed --
    /// the bits themselves cannot say.
    pub fn extract(self: Field, body: []const u8, index: u16) ?i64 {
        if (index >= self.count) return null;
        const start = self.bit_offset + @as(u32, self.bit_size) * index;
        if (self.bit_size == 0 or self.bit_size > 32) return null;
        if (start + self.bit_size > body.len * 8) return null;

        var raw: u64 = 0;
        var taken: u16 = 0;
        while (taken < self.bit_size) {
            const bit = start + taken;
            const byte = body[bit / 8];
            const value: u64 = (byte >> @intCast(bit % 8)) & 1;
            raw |= value << @intCast(taken);
            taken += 1;
        }

        if (self.logical_min < 0 and self.bit_size < 64) {
            const sign_bit = @as(u64, 1) << @intCast(self.bit_size - 1);
            if (raw & sign_bit != 0) {
                const extended = raw | ~((@as(u64, 1) << @intCast(self.bit_size)) - 1);
                return @bitCast(extended);
            }
        }
        return @intCast(raw);
    }
};

// ---------------------------------------------------------------------------
// The parser
// ---------------------------------------------------------------------------

/// Item tags, by type. Section 6.2.2.4 through 6.2.2.8.
const main_tag = struct {
    const input = 0x8;
    const output = 0x9;
    const collection = 0xA;
    const feature = 0xB;
    const end_collection = 0xC;
};

const global_tag = struct {
    const usage_page = 0x0;
    const logical_minimum = 0x1;
    const logical_maximum = 0x2;
    const physical_minimum = 0x3;
    const physical_maximum = 0x4;
    const unit_exponent = 0x5;
    const unit = 0x6;
    const report_size = 0x7;
    const report_id = 0x8;
    const report_count = 0x9;
    const push = 0xA;
    const pop = 0xB;
};

const local_tag = struct {
    const usage = 0x0;
    const usage_minimum = 0x1;
    const usage_maximum = 0x2;
    const delimiter = 0xA;
};

/// The global item state, which `Push` and `Pop` save and restore.
const Globals = struct {
    usage_page: u16 = 0,
    logical_min: i32 = 0,
    logical_max: i32 = 0,
    physical_min: i32 = 0,
    physical_max: i32 = 0,
    unit: u32 = 0,
    unit_exponent: i32 = 0,
    report_size: u16 = 0,
    report_count: u16 = 0,
    report_id: u8 = 0,
};

/// How many report IDs one descriptor may use before the parser gives up.
///
/// A device with more than this many distinct reports is not something that
/// has been seen; the limit exists so that the bit-offset bookkeeping can be
/// a flat array rather than a map.
pub const max_report_ids = 32;

/// How deep `Push` may nest.
pub const max_global_depth = 8;

/// How deep collections may nest.
pub const max_collection_depth = 16;

/// How many usages one main item may list individually.
pub const max_usages = 128;

pub const Error = error{
    /// The descriptor ended in the middle of an item, or an item's length ran
    /// past the end.
    Malformed,
    /// An `End Collection` with no open collection, or a descriptor that ends
    /// with one still open.
    UnbalancedCollection,
    /// More nesting, report IDs or listed usages than this parser holds. The
    /// limits are `max_*` above.
    TooComplex,
};

/// Walks a descriptor and yields one `Field` per main item.
///
/// ```
/// var parser: hidapi.descriptor.Parser = .init(bytes);
/// while (try parser.next()) |field| {
///     if (field.kind != .input or field.flags.constant) continue;
///     for (0..field.count) |i| {
///         const value = field.extract(report, @intCast(i)) orelse continue;
///         std.debug.print("{x:0>8} = {d}\n", .{ field.usageAt(@intCast(i)) orelse 0, value });
///     }
/// }
/// ```
pub const Parser = struct {
    it: Iterator,

    globals: Globals = .{},
    global_stack: [max_global_depth]Globals = undefined,
    global_depth: u8 = 0,

    /// Local item state, cleared after every main item, as 6.2.2.8 requires.
    usage_buf: [max_usages]u32 = undefined,
    usage_len: u8 = 0,
    usage_min: ?u32 = null,
    usage_max: ?u32 = null,
    /// Depth of an open `Delimiter` set. Inside one, only the first usage is
    /// kept: the specification says the first is the preferred one and the
    /// rest are aliases for systems that do not understand it.
    delimiter_depth: u8 = 0,

    collections: [max_collection_depth]Collection = undefined,
    collection_depth: u8 = 0,

    /// Bit offsets reached so far, per report ID and per report type. The
    /// three types are laid out independently, which is why this is not one
    /// counter.
    report_ids: [max_report_ids]u8 = undefined,
    offsets: [max_report_ids][3]u32 = undefined,
    report_id_count: u8 = 0,

    pub fn init(bytes: []const u8) Parser {
        return .{ .it = .init(bytes) };
    }

    /// The next field, or `null` at the end of the descriptor.
    pub fn next(self: *Parser) Error!?Field {
        while (self.it.next()) |raw| {
            switch (raw.type) {
                .main => if (try self.main(raw)) |field| return field,
                .global => try self.global(raw),
                .local => try self.local(raw),
                // A long item, or a reserved short one. Both are skipped,
                // and neither clears the local state -- only a main item
                // does that.
                .reserved => {},
            }
        } else {
            if (self.it.index < self.it.bytes.len) return error.Malformed;
            if (self.collection_depth != 0) return error.UnbalancedCollection;
            return null;
        }
    }

    fn main(self: *Parser, raw: RawItem) Error!?Field {
        defer self.clearLocals();

        switch (raw.tag) {
            main_tag.collection => {
                if (self.collection_depth >= max_collection_depth) return error.TooComplex;
                // A collection's usage is the first one declared for it.
                const usage = self.firstLocalUsage();
                self.collections[self.collection_depth] = .{
                    .type = @enumFromInt(@as(u8, @truncate(raw.unsigned()))),
                    .usage_page = @truncate(usage >> 16),
                    .usage = @truncate(usage),
                };
                self.collection_depth += 1;
                return null;
            },
            main_tag.end_collection => {
                if (self.collection_depth == 0) return error.UnbalancedCollection;
                self.collection_depth -= 1;
                return null;
            },
            main_tag.input, main_tag.output, main_tag.feature => {},
            // A main item this parser does not know. Its local state is still
            // consumed, which is what `defer` above does.
            else => return null,
        }

        const kind: Kind = switch (raw.tag) {
            main_tag.input => .input,
            main_tag.output => .output,
            else => .feature,
        };

        const slot = try self.reportSlot(self.globals.report_id);
        const bit_offset = self.offsets[slot][@intFromEnum(kind)];
        const total = @as(u32, self.globals.report_size) * self.globals.report_count;
        self.offsets[slot][@intFromEnum(kind)] = bit_offset + total;

        return .{
            .report_id = self.globals.report_id,
            .kind = kind,
            .bit_offset = bit_offset,
            .bit_size = self.globals.report_size,
            .count = self.globals.report_count,
            .usage_page = self.globals.usage_page,
            .usages = self.resolveUsages(),
            .logical_min = self.globals.logical_min,
            .logical_max = self.globals.logical_max,
            .physical_min = self.globals.physical_min,
            .physical_max = self.globals.physical_max,
            .unit = self.globals.unit,
            .unit_exponent = self.globals.unit_exponent,
            .flags = @bitCast(raw.unsigned()),
            .collections = self.collections[0..self.collection_depth],
        };
    }

    fn global(self: *Parser, raw: RawItem) Error!void {
        switch (raw.tag) {
            global_tag.usage_page => self.globals.usage_page = @truncate(raw.unsigned()),
            global_tag.logical_minimum => self.globals.logical_min = raw.signed(),
            global_tag.logical_maximum => {
                // A logical maximum is signed by the specification, and a
                // device declaring a byte field writes 255 in one byte, which
                // read as signed is -1. Taking the unsigned reading when the
                // minimum is not negative is what every other parser does,
                // and without it half the fields on a real device come back
                // with an inverted range.
                self.globals.logical_max = if (self.globals.logical_min >= 0)
                    @bitCast(raw.unsigned())
                else
                    raw.signed();
            },
            global_tag.physical_minimum => self.globals.physical_min = raw.signed(),
            global_tag.physical_maximum => {
                self.globals.physical_max = if (self.globals.physical_min >= 0)
                    @bitCast(raw.unsigned())
                else
                    raw.signed();
            },
            global_tag.unit_exponent => {
                // A four bit two's complement value, so 0xF is -1.
                const nibble: u4 = @truncate(raw.unsigned());
                self.globals.unit_exponent = @as(i4, @bitCast(nibble));
            },
            global_tag.unit => self.globals.unit = raw.unsigned(),
            global_tag.report_size => self.globals.report_size = @truncate(raw.unsigned()),
            global_tag.report_id => self.globals.report_id = @truncate(raw.unsigned()),
            global_tag.report_count => self.globals.report_count = @truncate(raw.unsigned()),
            global_tag.push => {
                if (self.global_depth >= max_global_depth) return error.TooComplex;
                self.global_stack[self.global_depth] = self.globals;
                self.global_depth += 1;
            },
            global_tag.pop => {
                if (self.global_depth == 0) return error.Malformed;
                self.global_depth -= 1;
                self.globals = self.global_stack[self.global_depth];
            },
            else => {},
        }
    }

    fn local(self: *Parser, raw: RawItem) Error!void {
        switch (raw.tag) {
            local_tag.usage => {
                // Inside a delimited set only the first usage counts; the
                // rest are aliases of it.
                if (self.delimiter_depth > 0 and self.usage_len > 0) return;
                if (self.usage_len >= max_usages) return error.TooComplex;
                self.usage_buf[self.usage_len] = self.extendedUsage(raw);
                self.usage_len += 1;
            },
            local_tag.usage_minimum => self.usage_min = self.extendedUsage(raw),
            local_tag.usage_maximum => self.usage_max = self.extendedUsage(raw),
            local_tag.delimiter => {
                if (raw.unsigned() != 0) {
                    self.delimiter_depth +|= 1;
                } else if (self.delimiter_depth > 0) {
                    self.delimiter_depth -= 1;
                }
            },
            // Designator and string items carry indices into descriptors this
            // library does not read, so they are consumed and dropped.
            else => {},
        }
    }

    /// A usage item of four bytes carries its own page in the high half; a
    /// shorter one falls under the global usage page.
    fn extendedUsage(self: *const Parser, raw: RawItem) u32 {
        const value = raw.unsigned();
        if (raw.data.len == 4) return value;
        return (@as(u32, self.globals.usage_page) << 16) | value;
    }

    fn firstLocalUsage(self: *const Parser) u32 {
        if (self.usage_len > 0) return self.usage_buf[0];
        if (self.usage_min) |min| return min;
        return @as(u32, self.globals.usage_page) << 16;
    }

    fn resolveUsages(self: *const Parser) Usages {
        if (self.usage_min) |min| {
            // A range wins over a list: a descriptor that declares both is
            // describing a range whose members it also happens to name.
            return .{ .range = .{ .min = min, .max = self.usage_max orelse min } };
        }
        if (self.usage_len > 0) return .{ .list = self.usage_buf[0..self.usage_len] };
        return .none;
    }

    fn clearLocals(self: *Parser) void {
        self.usage_len = 0;
        self.usage_min = null;
        self.usage_max = null;
        self.delimiter_depth = 0;
    }

    /// The bookkeeping slot for one report ID, creating it on first sight.
    fn reportSlot(self: *Parser, id: u8) Error!u8 {
        for (self.report_ids[0..self.report_id_count], 0..) |seen, i| {
            if (seen == id) return @intCast(i);
        }
        if (self.report_id_count >= max_report_ids) return error.TooComplex;
        const slot = self.report_id_count;
        self.report_ids[slot] = id;
        self.offsets[slot] = @splat(0);
        self.report_id_count += 1;
        return slot;
    }
};

/// The length in bytes of one report, counting the report ID byte when the
/// descriptor uses them.
///
/// Walks the whole descriptor, so a caller wanting several lengths should
/// collect them from one `Parser` pass instead.
pub fn reportLength(bytes: []const u8, kind: Kind, report_id: u8) Error!usize {
    var parser: Parser = .init(bytes);
    var bits: u32 = 0;
    var numbered = false;
    while (try parser.next()) |field| {
        if (field.report_id != 0) numbered = true;
        if (field.kind != kind or field.report_id != report_id) continue;
        bits = @max(bits, field.bit_offset + field.totalBits());
    }
    if (bits == 0) return 0;
    return (bits + 7) / 8 + @intFromBool(numbered);
}

// ---------------------------------------------------------------------------
// Parser tests
//
// The two descriptors below were taken verbatim off devices on my desk, and
// every assertion about them was worked out by hand from the bytes. They are
// the useful kind of fixture: a real mouse exercises a usage range, a usage
// list, three different usage pages and a signed sixteen bit field, and a real
// keyboard exercises input, output and feature reports laid out independently,
// an array item and constant padding.
// ---------------------------------------------------------------------------

/// A Logitech G703 mouse. No report IDs, one eight byte input report.
const mouse_descriptor = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x02, // Usage (Mouse)
    0xA1, 0x01, // Collection (Application)
    0x09, 0x01, //   Usage (Pointer)
    0xA1, 0x00, //   Collection (Physical)
    0x95, 0x10, //     Report Count (16)
    0x75, 0x01, //     Report Size (1)
    0x15, 0x00, //     Logical Minimum (0)
    0x25, 0x01, //     Logical Maximum (1)
    0x05, 0x09, //     Usage Page (Button)
    0x19, 0x01, //     Usage Minimum (1)
    0x29, 0x10, //     Usage Maximum (16)
    0x81, 0x02, //     Input (Data, Var, Abs)
    0x95, 0x02, //     Report Count (2)
    0x75, 0x10, //     Report Size (16)
    0x16, 0x01, 0x80, //     Logical Minimum (-32767)
    0x26, 0xFF, 0x7F, //     Logical Maximum (32767)
    0x05, 0x01, //     Usage Page (Generic Desktop)
    0x09, 0x30, //     Usage (X)
    0x09, 0x31, //     Usage (Y)
    0x81, 0x06, //     Input (Data, Var, Rel)
    0x95, 0x01, //     Report Count (1)
    0x75, 0x08, //     Report Size (8)
    0x15, 0x81, //     Logical Minimum (-127)
    0x25, 0x7F, //     Logical Maximum (127)
    0x09, 0x38, //     Usage (Wheel)
    0x81, 0x06, //     Input (Data, Var, Rel)
    0x95, 0x01, //     Report Count (1)
    0x05, 0x0C, //     Usage Page (Consumer)
    0x0A, 0x38, 0x02, //     Usage (AC Pan)
    0x81, 0x06, //     Input (Data, Var, Rel)
    0xC0, //   End Collection
    0xC0, // End Collection
};

/// A YubiKey's keyboard interface. Input, output and feature reports.
const keyboard_descriptor = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x06, // Usage (Keyboard)
    0xA1, 0x01, // Collection (Application)
    0x05, 0x07, //   Usage Page (Keyboard/Keypad)
    0x19, 0xE0, //   Usage Minimum (Left Control)
    0x29, 0xE7, //   Usage Maximum (Right GUI)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x08, //   Report Count (8)
    0x81, 0x02, //   Input (Data, Var, Abs)      -- the eight modifier keys
    0x95, 0x01, //   Report Count (1)
    0x75, 0x08, //   Report Size (8)
    0x81, 0x01, //   Input (Cnst, Ary, Abs)      -- one reserved byte
    0x95, 0x05, //   Report Count (5)
    0x75, 0x01, //   Report Size (1)
    0x05, 0x08, //   Usage Page (LED)
    0x19, 0x01, //   Usage Minimum (Num Lock)
    0x29, 0x05, //   Usage Maximum (Kana)
    0x91, 0x02, //   Output (Data, Var, Abs)     -- five LEDs
    0x95, 0x01, //   Report Count (1)
    0x75, 0x03, //   Report Size (3)
    0x91, 0x01, //   Output (Cnst, Ary, Abs)     -- three bits of padding
    0x95, 0x06, //   Report Count (6)
    0x75, 0x08, //   Report Size (8)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x65, //   Logical Maximum (101)
    0x05, 0x07, //   Usage Page (Keyboard/Keypad)
    0x19, 0x00, //   Usage Minimum (0)
    0x29, 0x65, //   Usage Maximum (101)
    0x81, 0x00, //   Input (Data, Ary, Abs)      -- six key slots
    0x09, 0x03, //   Usage (0x03)
    0x75, 0x08, //   Report Size (8)
    0x95, 0x08, //   Report Count (8)
    0xB1, 0x02, //   Feature (Data, Var, Abs)
    0xC0, // End Collection
};

fn collect(bytes: []const u8, out: *std.ArrayList(Field), gpa: std.mem.Allocator) !void {
    var parser: Parser = .init(bytes);
    while (try parser.next()) |field| {
        // The collections and usage list alias the parser, so anything kept
        // past the next call has to be copied. The tests only keep the scalar
        // parts, which is the usual thing to want.
        var copy = field;
        copy.collections = &.{};
        if (copy.usages == .list) copy.usages = .none;
        try out.append(gpa, copy);
    }
}

test "a real mouse descriptor parses field by field" {
    const gpa = std.testing.allocator;
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(gpa);
    try collect(&mouse_descriptor, &fields, gpa);

    // Four Input items: buttons, X and Y together, the wheel, and AC Pan.
    try std.testing.expectEqual(@as(usize, 4), fields.items.len);

    // Sixteen buttons, one bit each, first in the report.
    const buttons = fields.items[0];
    try std.testing.expectEqual(Kind.input, buttons.kind);
    try std.testing.expectEqual(@as(u32, 0), buttons.bit_offset);
    try std.testing.expectEqual(@as(u16, 1), buttons.bit_size);
    try std.testing.expectEqual(@as(u16, 16), buttons.count);
    try std.testing.expectEqual(@as(u16, 0x09), buttons.usage_page);
    try std.testing.expectEqual(@as(i32, 0), buttons.logical_min);
    try std.testing.expectEqual(@as(i32, 1), buttons.logical_max);
    try std.testing.expect(buttons.flags.variable);
    try std.testing.expect(!buttons.flags.relative);
    // A usage range, so element three is button four.
    try std.testing.expectEqual(@as(?u32, 0x0009_0004), buttons.usageAt(3));

    // X and Y: one main item, count two, with two usages listed.
    const xy = fields.items[1];
    try std.testing.expectEqual(@as(u32, 16), xy.bit_offset);
    try std.testing.expectEqual(@as(u16, 16), xy.bit_size);
    try std.testing.expectEqual(@as(u16, 2), xy.count);
    try std.testing.expectEqual(@as(i32, -32767), xy.logical_min);
    try std.testing.expectEqual(@as(i32, 32767), xy.logical_max);
    try std.testing.expect(xy.flags.relative);

    const wheel = fields.items[2];
    try std.testing.expectEqual(@as(u32, 48), wheel.bit_offset);
    try std.testing.expectEqual(@as(i32, -127), wheel.logical_min);
    try std.testing.expectEqual(@as(i32, 127), wheel.logical_max);

    // The consumer page's AC Pan. Its usage is a listed one, which `collect`
    // drops because the list aliases the parser -- see the streaming test
    // below for the usage itself.
    const pan = fields.items[3];
    try std.testing.expectEqual(@as(u32, 56), pan.bit_offset);
    try std.testing.expectEqual(@as(u16, 0x0C), pan.usage_page);

    // Eight bytes in total, and no report ID byte.
    try std.testing.expectEqual(@as(usize, 8), try reportLength(&mouse_descriptor, .input, 0));
}

test "usages resolve per element for a list and for a range" {
    var parser: Parser = .init(&mouse_descriptor);

    _ = try parser.next(); // buttons
    const xy = (try parser.next()).?;
    // Listed individually, so element zero is X and element one is Y.
    try std.testing.expectEqual(@as(?u32, 0x0001_0030), xy.usageAt(0));
    try std.testing.expectEqual(@as(?u32, 0x0001_0031), xy.usageAt(1));
    try std.testing.expectEqual(@as(?u32, null), xy.usageAt(2));

    _ = try parser.next(); // wheel
    const pan = (try parser.next()).?;
    // A four byte usage item, carrying its own page in the high half, which
    // has to win over the global usage page rather than being truncated into
    // it.
    try std.testing.expectEqual(@as(?u32, 0x000C_0238), pan.usageAt(0));
}

test "a collection path is reported outermost first" {
    var parser: Parser = .init(&mouse_descriptor);
    const buttons = (try parser.next()).?;

    try std.testing.expectEqual(@as(usize, 2), buttons.collections.len);
    try std.testing.expectEqual(CollectionType.application, buttons.collections[0].type);
    try std.testing.expectEqual(@as(u16, 0x01), buttons.collections[0].usage_page);
    try std.testing.expectEqual(@as(u16, 0x02), buttons.collections[0].usage); // Mouse
    try std.testing.expectEqual(CollectionType.physical, buttons.collections[1].type);
    try std.testing.expectEqual(@as(u16, 0x01), buttons.collections[1].usage); // Pointer
}

test "a real report decodes into the values it carries" {
    var parser: Parser = .init(&mouse_descriptor);
    const buttons = (try parser.next()).?;
    const xy = (try parser.next()).?;
    const wheel = (try parser.next()).?;

    // Button 1 down, X = -2, Y = +1, wheel = -1.
    const report = [_]u8{
        0x01, 0x00, // buttons 1..16
        0xFE, 0xFF, // X = -2
        0x01, 0x00, // Y = 1
        0xFF, // wheel = -1
        0x00, // AC Pan = 0
    };

    try std.testing.expectEqual(@as(?i64, 1), buttons.extract(&report, 0));
    try std.testing.expectEqual(@as(?i64, 0), buttons.extract(&report, 1));
    // Signed, because the logical minimum is negative.
    try std.testing.expectEqual(@as(?i64, -2), xy.extract(&report, 0));
    try std.testing.expectEqual(@as(?i64, 1), xy.extract(&report, 1));
    try std.testing.expectEqual(@as(?i64, -1), wheel.extract(&report, 0));

    // A report too short for the field is not guessed at.
    try std.testing.expectEqual(@as(?i64, null), wheel.extract(report[0..4], 0));
}

test "the three report types are laid out independently" {
    const gpa = std.testing.allocator;
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(gpa);
    try collect(&keyboard_descriptor, &fields, gpa);

    try std.testing.expectEqual(@as(usize, 6), fields.items.len);

    // Input: modifiers at bit 0, a reserved byte at 8, six key slots at 16.
    try std.testing.expectEqual(Kind.input, fields.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0), fields.items[0].bit_offset);
    try std.testing.expectEqual(@as(u32, 8), fields.items[1].bit_offset);
    try std.testing.expect(fields.items[1].flags.constant);
    try std.testing.expectEqual(@as(u32, 16), fields.items[4].bit_offset);

    // Output starts again at bit 0 rather than continuing from the input.
    try std.testing.expectEqual(Kind.output, fields.items[2].kind);
    try std.testing.expectEqual(@as(u32, 0), fields.items[2].bit_offset);
    try std.testing.expectEqual(@as(u32, 5), fields.items[3].bit_offset);

    // And so does the feature report.
    try std.testing.expectEqual(Kind.feature, fields.items[5].kind);
    try std.testing.expectEqual(@as(u32, 0), fields.items[5].bit_offset);

    try std.testing.expectEqual(@as(usize, 8), try reportLength(&keyboard_descriptor, .input, 0));
    try std.testing.expectEqual(@as(usize, 1), try reportLength(&keyboard_descriptor, .output, 0));
    try std.testing.expectEqual(@as(usize, 8), try reportLength(&keyboard_descriptor, .feature, 0));
}

test "an array item has no per-element usage" {
    const gpa = std.testing.allocator;
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(gpa);
    try collect(&keyboard_descriptor, &fields, gpa);

    const keys = fields.items[4];
    try std.testing.expect(!keys.flags.variable);
    try std.testing.expectEqual(@as(u16, 6), keys.count);
    // A slot holds a key code rather than meaning something on its own, so
    // asking what element two *is* has no answer -- the usage range describes
    // the values that may appear, not the slots.
    try std.testing.expectEqual(@as(?u32, null), keys.usageAt(2));
}

test "a logical maximum of 255 is not minus one" {
    // The specification calls the item signed, and a device writes 255 in one
    // byte. Read signed that is -1, which inverts the range of a great many
    // real fields.
    const bytes = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x15, 0x00, // Logical Minimum (0)
        0x26, 0xFF, 0x00, // Logical Maximum (255), two bytes
        0x25, 0xFF, // Logical Maximum (255), one byte
        0x75, 0x08,
        0x95, 0x01,
        0x09, 0x30,
        0x81, 0x02,
        0xC0,
    };
    var parser: Parser = .init(&bytes);
    const field = (try parser.next()).?;
    try std.testing.expectEqual(@as(i32, 0), field.logical_min);
    try std.testing.expectEqual(@as(i32, 255), field.logical_max);
}

test "push and pop save and restore the global state" {
    const bytes = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x75, 0x08, 0x95, 0x01, 0x15, 0x00,
        0x25, 0x7F,
        0xA4, // Push
        0x75, 0x10, // Report Size (16)
        0x09, 0x30, 0x81, 0x02, // a 16 bit field
        0xB4, // Pop
        0x09, 0x31, 0x81, 0x02, // back to 8 bits
        0xC0,
    };
    var parser: Parser = .init(&bytes);
    const wide = (try parser.next()).?;
    try std.testing.expectEqual(@as(u16, 16), wide.bit_size);
    const narrow = (try parser.next()).?;
    try std.testing.expectEqual(@as(u16, 8), narrow.bit_size);
    try std.testing.expectEqual(@as(u32, 16), narrow.bit_offset);
}

test "local state is cleared by every main item" {
    // The usage declared before the first Input must not leak onto the
    // second, which would otherwise report the same usage twice.
    const bytes = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x75, 0x08, 0x95, 0x01, 0x15, 0x00,
        0x25, 0x7F, 0x09, 0x30, 0x81, 0x02,
        0x81, 0x02, // no usage of its own
        0xC0,
    };
    var parser: Parser = .init(&bytes);
    const first = (try parser.next()).?;
    try std.testing.expectEqual(@as(?u32, 0x0001_0030), first.usageAt(0));
    const second = (try parser.next()).?;
    try std.testing.expectEqual(@as(?u32, null), second.usageAt(0));
}

test "report ids give each report its own bit offsets" {
    const bytes = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x75, 0x08, 0x95, 0x01, 0x15, 0x00,
        0x25, 0x7F,
        0x85, 0x01, // Report ID (1)
        0x09, 0x30,
        0x81, 0x02,
        0x85, 0x02, // Report ID (2)
        0x09, 0x31,
        0x81, 0x02,
        0x85, 0x01, // back to Report ID 1
        0x09, 0x32,
        0x81, 0x02,
        0xC0,
    };
    var parser: Parser = .init(&bytes);
    const a = (try parser.next()).?;
    const b = (try parser.next()).?;
    const c = (try parser.next()).?;

    try std.testing.expectEqual(@as(u8, 1), a.report_id);
    try std.testing.expectEqual(@as(u32, 0), a.bit_offset);
    // Report 2 starts over.
    try std.testing.expectEqual(@as(u8, 2), b.report_id);
    try std.testing.expectEqual(@as(u32, 0), b.bit_offset);
    // And report 1 carries on where it left off.
    try std.testing.expectEqual(@as(u8, 1), c.report_id);
    try std.testing.expectEqual(@as(u32, 8), c.bit_offset);

    // The length counts the report ID byte, because this device sends one.
    try std.testing.expectEqual(@as(usize, 3), try reportLength(&bytes, .input, 1));
}

test "an unbalanced collection is an error rather than a guess" {
    // Ends with a collection still open.
    try std.testing.expectError(error.UnbalancedCollection, drain(&.{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
    }));
    // Closes one that was never opened.
    try std.testing.expectError(error.UnbalancedCollection, drain(&.{
        0x05, 0x01, 0xC0,
    }));
}

test "a truncated item is an error rather than a partial read" {
    // A usage page item that promises two bytes and supplies one.
    try std.testing.expectError(error.Malformed, drain(&.{ 0x06, 0x00 }));
}

fn drain(bytes: []const u8) Error!void {
    var parser: Parser = .init(bytes);
    while (try parser.next()) |_| {}
}

test "a long item is stepped over" {
    const bytes = [_]u8{
        0xFE, 0x02, 0x00, 0xAA, 0xBB, // long item, two data bytes
        0x05, 0x01, 0x09, 0x02, 0xA1,
        0x01, 0x75, 0x08, 0x95, 0x01,
        0x09, 0x30, 0x81, 0x02, 0xC0,
    };
    var parser: Parser = .init(&bytes);
    const field = (try parser.next()).?;
    try std.testing.expectEqual(@as(u16, 8), field.bit_size);
    try std.testing.expect(try parser.next() == null);
}
