// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Rebuilding a HID report descriptor from Windows' preparsed data.
//!
//! Windows does not keep the descriptor a device sent. The HID class driver
//! parses it once and keeps only its own form, so `getReportDescriptor` has
//! nothing to return -- which is why this exists. It is a port of the C
//! hidapi's `hidapi_descriptor_reconstruct.c`, and it is deliberately a close
//! one: the structure, the order of the passes and most of the variable names
//! follow the original so that the two can be read side by side when one of
//! them turns out to be wrong.
//!
//! **The result is equivalent, not identical.** The preparsed data has lost
//! things a descriptor had: where padding was, which items were grouped, any
//! global item the parser did not keep. What comes out describes the same
//! device -- same reports, same fields, same bit positions -- and will not be
//! byte-for-byte what the device sent. Anything comparing descriptors for
//! equality should not use this.
//!
//! The passes, in order:
//!
//!  1. Find, per collection and per report, the first and last bit its fields
//!     occupy.
//!  2. Walk the collection tree to get each node's depth and child count.
//!  3. Propagate bit ranges from children up to parents.
//!  4. Sort each collection's children by bit position, since the order
//!     Windows stores them in is not the order the descriptor had.
//!  5. Emit the collection and end-collection items into a list.
//!  6. Insert the input, output and feature items at their bit positions.
//!  7. Fill every gap with constant padding, including to the end of each
//!     report.
//!  8. Walk the list and write the items out.
//!
//! All of it runs in a `FixedBufferAllocator` over scratch the caller
//! supplied, so this allocates nothing of its own.

const std = @import("std");

const item = @import("item.zig");
const preparsed = @import("preparsed.zig");

const Cap = preparsed.Cap;
const LinkCollectionNode = preparsed.LinkCollectionNode;
const PreparsedData = preparsed.PreparsedData;

/// Input, output, feature -- the three report types, and the order Windows
/// stores them in.
const report_types = 3;

pub const Error = error{
    /// The blob is not recognisably preparsed data, or is one this code
    /// cannot read.
    Unsupported,
    /// `buf` is shorter than the descriptor.
    BufferTooSmall,
    /// The scratch buffer could not hold the working state.
    ScratchTooSmall,
};

/// What a node in the working list is.
const NodeType = enum { cap, padding, collection };

/// The item a node will become. The first three are numbered to match
/// Windows' report type indices, which is what lets a report type be used as
/// a main item type directly.
const MainItem = enum(u8) {
    input = 0,
    output = 1,
    feature = 2,
    collection = 3,
    collection_end = 4,
    delimiter_open = 5,
    delimiter_usage = 6,
    delimiter_close = 7,

    fn isReportItem(self: MainItem) bool {
        return switch (self) {
            .input, .output, .feature => true,
            else => false,
        };
    }
};

const Node = struct {
    first_bit: i32,
    last_bit: i32,
    type_of_node: NodeType,
    /// Index into the capability array, or -1 for a padding node.
    caps_index: i32,
    collection_index: i32,
    main_item_type: MainItem,
    report_id: u8,
    next: ?*Node = null,
};

/// The first and last bit some collection's fields occupy in some report.
const BitRange = struct {
    first: i32 = -1,
    last: i32 = -1,
};

/// The singly linked list the whole reconstruction is built in.
///
/// The operations are the three the C has, with the same meanings: `append`
/// puts a node at the very end wherever it is called from, `insertAfter` puts
/// one directly after a given node, and `searchForBitPosition` finds the node
/// to insert after.
const List = struct {
    arena: std.mem.Allocator,
    head: ?*Node = null,

    fn make(self: *List, node: Node) Error!*Node {
        const new = self.arena.create(Node) catch return error.ScratchTooSmall;
        new.* = node;
        new.next = null;
        return new;
    }

    /// Append at the end of the whole list.
    fn append(self: *List, node: Node) Error!*Node {
        const new = try self.make(node);
        var slot: *?*Node = &self.head;
        while (slot.*) |current| slot = &current.next;
        slot.* = new;
        return new;
    }

    /// Insert directly after `after`.
    fn insertAfter(self: *List, after: *Node, node: Node) Error!*Node {
        const new = try self.make(node);
        new.next = after.next;
        after.next = new;
        return new;
    }
};

/// Find the node to insert a field after: the last one whose successor is not
/// yet past `search_bit`.
///
/// Stops at a collection boundary, so a field never migrates out of the
/// collection it belongs to.
fn searchForBitPosition(start: *Node, search_bit: i32, main_item_type: MainItem, report_id: u8) *Node {
    var node = start;
    while (node.next) |next| {
        if (next.main_item_type == .collection or next.main_item_type == .collection_end) break;
        if (next.last_bit >= search_bit and
            next.report_id == report_id and
            next.main_item_type == main_item_type) break;
        node = next;
    }
    return node;
}

/// The bit a capability's field starts at.
///
/// `byte_position` counts the report ID byte, which is not part of the
/// descriptor's own numbering, hence the subtraction.
fn firstBitOf(cap: Cap) i32 {
    return (@as(i32, cap.byte_position) - 1) * 8 + cap.bit_position;
}

fn lastBitOf(cap: Cap) i32 {
    return firstBitOf(cap) + @as(i32, cap.report_size) * @as(i32, cap.report_count) - 1;
}

/// Maps a report ID onto a dense index.
///
/// The C dimensions its tables by all 256 possible report IDs, which for a
/// device with twenty collections is over a hundred kilobytes of mostly
/// nothing. A device uses a handful, so they are collected first and indexed
/// by position. Every loop the C writes as `for reportid_idx in 0..256`
/// becomes a loop over the ones that exist, which visits the same entries.
const ReportIds = struct {
    /// The distinct report IDs, in the order first seen.
    ids: []u8,
    /// `slot[id]` is its index in `ids`, or `none`.
    slot: [256]u8,

    const none = std.math.maxInt(u8);

    fn collect(arena: std.mem.Allocator, pp: PreparsedData) Error!ReportIds {
        var slot: [256]u8 = @splat(none);
        var count: usize = 0;
        for (0..report_types) |rt| {
            for (pp.caps(rt)) |cap| {
                if (slot[cap.report_id] == none) {
                    if (count >= none) return error.Unsupported;
                    slot[cap.report_id] = @intCast(count);
                    count += 1;
                }
            }
        }
        const ids = arena.alloc(u8, count) catch return error.ScratchTooSmall;
        for (0..256) |id| {
            if (slot[id] != none) ids[slot[id]] = @intCast(id);
        }
        return .{ .ids = ids, .slot = slot };
    }
};

/// Everything the passes share.
const Builder = struct {
    arena: std.mem.Allocator,
    pp: PreparsedData,
    nodes: []const LinkCollectionNode,
    report_ids: ReportIds,

    /// `[collection][report id slot][report type]`.
    bit_range: []BitRange,
    /// Depth of each collection in the tree, or -1 if unreached.
    levels: []i32,
    /// How many children each collection has.
    child_count: []i32,
    /// Each collection's children, sorted by bit position.
    child_order: [][]u16,
    /// The list node that opens and closes each collection.
    begin_lookup: []?*Node,
    end_lookup: []?*Node,

    list: List,

    /// The capability at an absolute index, bounds-checked.
    ///
    /// The indices stored on nodes are absolute across the whole capability
    /// array, where `PreparsedData.caps` slices one report type, so this
    /// reaches past the slice on purpose.
    fn capAt(self: *Builder, index: i32) Error!Cap {
        if (index < 0) return error.Unsupported;
        const all = self.pp.allCaps();
        const i: usize = @intCast(index);
        if (i >= all.len) return error.Unsupported;
        return all[i];
    }

    fn rangeAt(self: *Builder, collection: usize, report_id: u8, rt: usize) *BitRange {
        const slot = self.report_ids.slot[report_id];
        std.debug.assert(slot != ReportIds.none);
        return &self.bit_range[(collection * self.report_ids.ids.len + slot) * report_types + rt];
    }
};

/// Rebuild the descriptor into `buf`, using `scratch` as working memory.
///
/// Pass an empty `buf` to measure: nothing is written, and the length that
/// would have been needed is returned as `error.BufferTooSmall` is *not*
/// raised -- see `measure`.
pub fn reconstruct(blob: []const u8, buf: []u8, scratch: []u8) Error![]const u8 {
    const w = try run(blob, buf, scratch);
    return w.finish() catch error.BufferTooSmall;
}

/// How many bytes the descriptor will take.
pub fn measure(blob: []const u8, scratch: []u8) Error!usize {
    const w = try run(blob, &.{}, scratch);
    return w.len;
}

fn run(blob: []const u8, buf: []u8, scratch: []u8) Error!item.Writer {
    const pp = try PreparsedData.init(blob);

    var fba: std.heap.FixedBufferAllocator = .init(scratch);
    const arena = fba.allocator();

    const nodes = pp.linkCollectionNodes();
    if (nodes.len == 0) return error.Unsupported;

    const report_ids: ReportIds = try .collect(arena, pp);

    var b: Builder = .{
        .arena = arena,
        .pp = pp,
        .nodes = nodes,
        .report_ids = report_ids,
        .bit_range = arena.alloc(BitRange, nodes.len * @max(report_ids.ids.len, 1) * report_types) catch
            return error.ScratchTooSmall,
        .levels = arena.alloc(i32, nodes.len) catch return error.ScratchTooSmall,
        .child_count = arena.alloc(i32, nodes.len) catch return error.ScratchTooSmall,
        .child_order = arena.alloc([]u16, nodes.len) catch return error.ScratchTooSmall,
        .begin_lookup = arena.alloc(?*Node, nodes.len) catch return error.ScratchTooSmall,
        .end_lookup = arena.alloc(?*Node, nodes.len) catch return error.ScratchTooSmall,
        .list = .{ .arena = arena },
    };
    @memset(b.bit_range, .{});
    @memset(b.levels, -1);
    @memset(b.child_count, 0);
    @memset(b.child_order, &.{});
    @memset(b.begin_lookup, null);
    @memset(b.end_lookup, null);

    try collectBitRanges(&b);
    const max_level = try walkTree(&b);
    propagateBitRanges(&b, max_level);
    try orderChildren(&b);
    try buildCollectionList(&b);
    try insertReportItems(&b);
    try insertPadding(&b);

    var writer: item.Writer = .init(buf);
    try encode(&b, &writer);
    return writer;
}

/// Pass 1: the bit range each collection occupies in each report.
fn collectBitRanges(b: *Builder) Error!void {
    for (0..report_types) |rt| {
        for (b.pp.caps(rt)) |cap| {
            if (cap.link_collection >= b.nodes.len) return error.Unsupported;
            const first = firstBitOf(cap);
            const last = lastBitOf(cap);
            const range = b.rangeAt(cap.link_collection, cap.report_id, rt);
            if (range.first == -1 or range.first > first) range.first = first;
            if (range.last < last) range.last = last;
        }
    }
}

/// Pass 2: each collection's depth, and how many children it has.
fn walkTree(b: *Builder) Error!i32 {
    var max_level: i32 = 0;
    var level: i32 = 0;
    var idx: u16 = 0;
    // Bounded so that a cyclic tree -- which a corrupt blob could describe --
    // cannot spin here forever.
    var steps: usize = 0;
    const limit = b.nodes.len * 4 + 16;

    while (level >= 0) {
        steps += 1;
        if (steps > limit) return error.Unsupported;
        if (idx >= b.nodes.len) return error.Unsupported;

        b.levels[idx] = level;
        const node = b.nodes[idx];
        if (node.number_of_children > 0 and
            node.first_child < b.nodes.len and
            b.levels[node.first_child] == -1)
        {
            level += 1;
            b.levels[idx] = level;
            if (max_level < level) max_level = level;
            b.child_count[idx] += 1;
            idx = node.first_child;
        } else if (node.next_sibling != 0) {
            if (node.parent >= b.nodes.len) return error.Unsupported;
            b.child_count[node.parent] += 1;
            idx = node.next_sibling;
        } else {
            level -= 1;
            if (level >= 0) {
                if (node.parent >= b.nodes.len) return error.Unsupported;
                idx = node.parent;
            }
        }
    }
    return max_level;
}

/// Pass 3: a parent's range covers its children's.
fn propagateBitRanges(b: *Builder, max_level: i32) void {
    var level = max_level - 1;
    while (level >= 0) : (level -= 1) {
        for (0..b.nodes.len) |idx| {
            if (b.levels[idx] != level) continue;
            var child = b.nodes[idx].first_child;
            while (child != 0 and child < b.nodes.len) {
                for (b.report_ids.ids) |id| {
                    for (0..report_types) |rt| {
                        const from = b.rangeAt(child, id, rt).*;
                        const into = b.rangeAt(idx, id, rt);
                        if (from.first != -1 and (into.first == -1 or into.first > from.first)) {
                            into.first = from.first;
                        }
                        if (into.last < from.last) into.last = from.last;
                    }
                }
                child = b.nodes[child].next_sibling;
            }
        }
    }
}

/// Pass 4: put each collection's children in bit order.
///
/// Windows returns them in reverse, and reversing is enough whenever no field
/// positions have to be considered -- but not always, hence the sort.
fn orderChildren(b: *Builder) Error!void {
    for (0..b.nodes.len) |idx| {
        const count: usize = @intCast(@max(b.child_count[idx], 0));
        if (count == 0) continue;

        const order = b.arena.alloc(u16, count) catch return error.ScratchTooSmall;
        b.child_order[idx] = order;

        // Reverse of the order Windows stores them in.
        var child = b.nodes[idx].first_child;
        var slot = count;
        while (slot > 0) {
            slot -= 1;
            if (child >= b.nodes.len) return error.Unsupported;
            order[slot] = child;
            child = b.nodes[child].next_sibling;
            if (child == 0) break;
        }

        if (count > 1) {
            // A bubble sort, as the original, over every report and type.
            for (0..report_types) |rt| {
                for (b.report_ids.ids) |id| {
                    for (1..count) |i| {
                        const prev = b.rangeAt(order[i - 1], id, rt).first;
                        const cur = b.rangeAt(order[i], id, rt).first;
                        if (prev != -1 and cur != -1 and prev > cur) {
                            std.mem.swap(u16, &order[i - 1], &order[i]);
                        }
                    }
                }
            }
        }
    }
}

/// Pass 5: the collection and end-collection items.
fn buildCollectionList(b: *Builder) Error!void {
    const last_written = b.arena.alloc(i32, b.nodes.len) catch return error.ScratchTooSmall;
    @memset(last_written, -1);

    var level: i32 = 0;
    var idx: u16 = 0;
    var first_delimiter: ?*Node = null;
    var delimiter_close: ?*Node = null;

    b.begin_lookup[0] = try b.list.append(.{
        .first_bit = 0,
        .last_bit = 0,
        .type_of_node = .collection,
        .caps_index = 0,
        .collection_index = 0,
        .main_item_type = .collection,
        .report_id = 0,
    });

    var steps: usize = 0;
    const limit = b.nodes.len * 8 + 32;

    while (level >= 0) {
        steps += 1;
        if (steps > limit) return error.Unsupported;

        const count: usize = @intCast(@max(b.child_count[idx], 0));
        if (count != 0 and last_written[idx] == -1) {
            last_written[idx] = b.child_order[idx][0];
            idx = b.child_order[idx][0];
            try openCollection(b, idx, &level, &first_delimiter, &delimiter_close);
        } else if (count > 1 and last_written[idx] != b.child_order[idx][count - 1]) {
            var next_child: usize = 1;
            while (last_written[idx] != b.child_order[idx][next_child - 1]) : (next_child += 1) {
                if (next_child >= count) return error.Unsupported;
            }
            last_written[idx] = b.child_order[idx][next_child];
            idx = b.child_order[idx][next_child];
            try openCollection(b, idx, &level, &first_delimiter, &delimiter_close);
        } else {
            level -= 1;
            b.end_lookup[idx] = try b.list.append(.{
                .first_bit = 0,
                .last_bit = 0,
                .type_of_node = .collection,
                .caps_index = 0,
                .collection_index = @intCast(idx),
                .main_item_type = .collection_end,
                .report_id = 0,
            });
            idx = b.nodes[idx].parent;
        }
    }
}

/// Emit the opening of one collection, aliased or not.
///
/// In a descriptor the first usage declared is the preferred one; in Windows'
/// structures the preferred one is the *last* of an aliased sequence. So an
/// alias is emitted by inserting each usage before the ones already written,
/// which reverses them back.
fn openCollection(
    b: *Builder,
    idx: u16,
    level: *i32,
    first_delimiter: *?*Node,
    delimiter_close: *?*Node,
) Error!void {
    const node = b.nodes[idx];
    const base: Node = .{
        .first_bit = 0,
        .last_bit = 0,
        .type_of_node = .collection,
        .caps_index = 0,
        .collection_index = @intCast(idx),
        .main_item_type = .collection,
        .report_id = 0,
    };

    if (node.isAlias() and first_delimiter.* == null) {
        first_delimiter.* = b.list.head;
        var usage_node = base;
        usage_node.main_item_type = .delimiter_usage;
        b.begin_lookup[idx] = try b.list.append(usage_node);
        var close_node = base;
        close_node.main_item_type = .delimiter_close;
        b.begin_lookup[idx] = try b.list.append(close_node);
        delimiter_close.* = b.list.head;
    } else if (node.isAlias() and first_delimiter.* != null) {
        var usage_node = base;
        usage_node.main_item_type = .delimiter_usage;
        b.begin_lookup[idx] = try b.list.insertAfter(first_delimiter.*.?, usage_node);
    } else if (!node.isAlias() and first_delimiter.* != null) {
        var usage_node = base;
        usage_node.main_item_type = .delimiter_usage;
        b.begin_lookup[idx] = try b.list.insertAfter(first_delimiter.*.?, usage_node);
        var open_node = base;
        open_node.main_item_type = .delimiter_open;
        b.begin_lookup[idx] = try b.list.insertAfter(first_delimiter.*.?, open_node);
        first_delimiter.* = null;
        if (delimiter_close.*) |close| b.list.head = close;
        delimiter_close.* = null;
    }

    if (!node.isAlias()) {
        b.begin_lookup[idx] = try b.list.append(base);
        level.* += 1;
    }
}

/// Pass 6: the input, output and feature items, at their bit positions.
fn insertReportItems(b: *Builder) Error!void {
    for (0..report_types) |rt| {
        var first_delimiter: ?*Node = null;
        var delimiter_close: ?*Node = null;

        const caps = b.pp.caps(rt);
        for (caps, 0..) |cap, i| {
            const caps_index: i32 = @intCast(b.pp.header.caps_info[rt].first_cap + i);
            var coll_begin = b.begin_lookup[cap.link_collection] orelse return error.Unsupported;

            const first_bit = firstBitOf(cap);
            const last_bit = lastBitOf(cap);

            // Which side of this collection's children the field belongs on.
            const order = b.child_order[cap.link_collection];
            for (order) |child| {
                if (first_bit < b.rangeAt(child, cap.report_id, rt).first) break;
                coll_begin = b.end_lookup[child] orelse coll_begin;
            }

            var list_node = searchForBitPosition(
                coll_begin,
                first_bit,
                @enumFromInt(@as(u8, @intCast(rt))),
                cap.report_id,
            );

            const base: Node = .{
                .first_bit = first_bit,
                .last_bit = last_bit,
                .type_of_node = .cap,
                .caps_index = caps_index,
                .collection_index = cap.link_collection,
                .main_item_type = @enumFromInt(@as(u8, @intCast(rt))),
                .report_id = cap.report_id,
            };

            if (cap.isAlias() and first_delimiter == null) {
                first_delimiter = list_node;
                var usage_node = base;
                usage_node.main_item_type = .delimiter_usage;
                _ = try b.list.insertAfter(list_node, usage_node);
                var close_node = base;
                close_node.main_item_type = .delimiter_close;
                list_node = try b.list.insertAfter(list_node, close_node);
                delimiter_close = list_node;
            } else if (cap.isAlias() and first_delimiter != null) {
                var usage_node = base;
                usage_node.main_item_type = .delimiter_usage;
                _ = try b.list.insertAfter(list_node, usage_node);
            } else if (!cap.isAlias() and first_delimiter != null) {
                var usage_node = base;
                usage_node.main_item_type = .delimiter_usage;
                _ = try b.list.insertAfter(list_node, usage_node);
                var open_node = base;
                open_node.main_item_type = .delimiter_open;
                _ = try b.list.insertAfter(list_node, open_node);
                first_delimiter = null;
                if (delimiter_close) |close| list_node = close;
                delimiter_close = null;
            }

            if (!cap.isAlias()) {
                _ = try b.list.insertAfter(list_node, base);
            }
        }
    }
}

/// Pass 7: constant padding for every gap, and to the end of each report.
///
/// The preparsed data records nothing about padding, so all of it is
/// reconstructed as constant fields. The eight-bit padding at the end of a
/// report is an assumption -- every descriptor seen in practice has it.
fn insertPadding(b: *Builder) Error!void {
    const slots = b.report_ids.ids.len;
    const last_bit = b.arena.alloc(i32, report_types * @max(slots, 1)) catch
        return error.ScratchTooSmall;
    const last_item = b.arena.alloc(?*Node, report_types * @max(slots, 1)) catch
        return error.ScratchTooSmall;
    @memset(last_bit, -1);
    @memset(last_item, null);

    const at = struct {
        fn index(rt: usize, slot: u8, n: usize) usize {
            return rt * n + slot;
        }
    }.index;

    var has_report_ids = false;
    var node_before_top_level_end: ?*Node = null;

    {
        var maybe = b.list.head;
        while (maybe) |node| {
            if (node.next == null) break;
            if (node.main_item_type.isReportItem() and node.first_bit != -1) {
                const rt = @intFromEnum(node.main_item_type);
                const slot = b.report_ids.slot[node.report_id];
                if (slot != ReportIds.none) {
                    const i = at(rt, slot, @max(slots, 1));
                    if (last_bit[i] + 1 != node.first_bit) {
                        if (last_item[i]) |previous| {
                            // The second condition keeps a multi-usage array
                            // -- several dedicated usages over the same bits
                            // -- from being padded apart.
                            if (previous.first_bit != node.first_bit) {
                                const insert_after = searchForBitPosition(
                                    previous,
                                    last_bit[i],
                                    node.main_item_type,
                                    node.report_id,
                                );
                                _ = try b.list.insertAfter(insert_after, .{
                                    .first_bit = last_bit[i] + 1,
                                    .last_bit = node.first_bit - 1,
                                    .type_of_node = .padding,
                                    .caps_index = -1,
                                    .collection_index = 0,
                                    .main_item_type = node.main_item_type,
                                    .report_id = node.report_id,
                                });
                            }
                        }
                    }
                    if (node.report_id != 0) has_report_ids = true;
                    last_bit[i] = node.last_bit;
                    last_item[i] = node;
                }
            }
            if (node.next) |next| {
                if (next.main_item_type == .collection_end) node_before_top_level_end = node;
            }
            maybe = node.next;
        }
    }

    // Eight-bit padding at the end of each report.
    for (0..report_types) |rt| {
        for (b.report_ids.ids) |id| {
            const slot = b.report_ids.slot[id];
            const i = at(rt, slot, @max(slots, 1));
            if (last_bit[i] == -1) continue;
            const padding = 8 - @rem(last_bit[i] + 1, 8);
            if (padding >= 8) continue;
            const after = last_item[i] orelse continue;
            _ = try b.list.insertAfter(after, .{
                .first_bit = last_bit[i] + 1,
                .last_bit = last_bit[i] + padding,
                .type_of_node = .padding,
                .caps_index = -1,
                .collection_index = 0,
                .main_item_type = @enumFromInt(@as(u8, @intCast(rt))),
                .report_id = id,
            });
            if (after == node_before_top_level_end) node_before_top_level_end = after.next;
            last_bit[i] += padding;
        }
    }

    // Whole-byte padding to the end of the report, which is only
    // reconstructable for a device without report IDs: only then is there one
    // report per type, so its length is the buffer length Windows reports.
    if (!has_report_ids) {
        for (0..report_types) |rt| {
            const info = b.pp.header.caps_info[rt];
            if (info.number_of_caps == 0 or info.report_byte_length == 0) continue;
            const slot = b.report_ids.slot[0];
            if (slot == ReportIds.none) continue;
            const i = at(rt, slot, @max(slots, 1));
            const padding = (@as(i32, info.report_byte_length) - 1) * 8 - (last_bit[i] + 1);
            if (padding <= 0) continue;
            const after = node_before_top_level_end orelse continue;
            _ = try b.list.insertAfter(after, .{
                .first_bit = last_bit[i] + 1,
                .last_bit = last_bit[i] + padding,
                .type_of_node = .padding,
                .caps_index = -1,
                .collection_index = 0,
                .main_item_type = @enumFromInt(@as(u8, @intCast(rt))),
                .report_id = 0,
            });
        }
    }
}

/// Pass 8: walk the list and write the descriptor.
///
/// Global items are only written when they change, which is what a real
/// descriptor does and what keeps the output a reasonable size. `report_count`
/// accumulates runs of identical fields so that several one-field
/// capabilities become one item with a count, which is how they were almost
/// certainly written in the first place.
fn encode(b: *Builder, w: *item.Writer) Error!void {
    var last_report_id: u8 = 0;
    var last_usage_page: u16 = 0;
    // Both physical limits being zero means "take the logical limits", per
    // the HID specification 6.2.2.7, so zero is the right starting point.
    var last_physical_min: i32 = 0;
    var last_physical_max: i32 = 0;
    var last_unit_exponent: u32 = 0;
    var last_unit: u32 = 0;
    // Set after a delimiter closes, because the usage has already been
    // written inside the delimited set.
    var inhibit_usage = false;
    var report_count: i32 = 0;

    var maybe = b.list.head;
    while (maybe) |node| : (maybe = node.next) {
        const rt: usize = @intFromEnum(node.main_item_type);
        const caps_index = node.caps_index;

        switch (node.main_item_type) {
            .collection => {
                const collection = b.nodes[@intCast(node.collection_index)];
                if (last_usage_page != collection.link_usage_page) {
                    try write(w, .global_usage_page, collection.link_usage_page);
                    last_usage_page = collection.link_usage_page;
                }
                if (inhibit_usage) {
                    inhibit_usage = false;
                } else {
                    try write(w, .local_usage, collection.link_usage);
                }
                try write(w, .main_collection, collection.collectionType());
                continue;
            },
            .collection_end => {
                try write(w, .main_collection_end, 0);
                continue;
            },
            .delimiter_open => {
                if (node.collection_index != -1) {
                    const collection = b.nodes[@intCast(node.collection_index)];
                    if (last_usage_page != collection.link_usage_page) {
                        try write(w, .global_usage_page, collection.link_usage_page);
                        last_usage_page = collection.link_usage_page;
                    }
                } else if (caps_index != 0) {
                    const cap = try b.capAt(caps_index);
                    if (cap.usage_page != last_usage_page) {
                        try write(w, .global_usage_page, cap.usage_page);
                        last_usage_page = cap.usage_page;
                    }
                }
                try write(w, .local_delimiter, 1);
                continue;
            },
            .delimiter_usage => {
                if (node.collection_index != -1) {
                    const collection = b.nodes[@intCast(node.collection_index)];
                    try write(w, .local_usage, collection.link_usage);
                }
                if (caps_index != 0) {
                    const cap = try b.capAt(caps_index);
                    try writeUsage(w, cap);
                }
                continue;
            },
            .delimiter_close => {
                try write(w, .local_delimiter, 0);
                inhibit_usage = true;
                continue;
            },
            else => {},
        }

        if (node.type_of_node == .padding) {
            const bits = node.last_bit - node.first_bit + 1;
            if (@rem(bits, 8) == 0) {
                try write(w, .global_report_size, 8);
                try write(w, .global_report_count, @divExact(bits, 8));
            } else {
                try write(w, .global_report_size, bits);
                try write(w, .global_report_count, 1);
            }
            // Constant and absolute. The other bits of a constant field do
            // not matter, and the preparsed data has not kept them.
            try writeMain(w, rt, 0x03);
            report_count = 0;
            continue;
        }

        const cap = try b.capAt(caps_index);

        if (last_report_id != cap.report_id) {
            try write(w, .global_report_id, cap.report_id);
            last_report_id = cap.report_id;
        }
        if (cap.usage_page != last_usage_page) {
            try write(w, .global_usage_page, cap.usage_page);
            last_usage_page = cap.usage_page;
        }

        if (cap.isButtonCap()) {
            if (cap.isRange()) {
                report_count += @as(i32, cap.usage.range.data_index_max) -
                    @as(i32, cap.usage.range.data_index_min);
            }

            if (inhibit_usage) {
                inhibit_usage = false;
            } else {
                try writeUsage(w, cap);
            }
            try writeDesignatorAndString(w, cap);

            if (try runsInto(b, node, cap, rt, true)) {
                if (node.next.?.first_bit != node.first_bit) report_count += 1;
                continue;
            }

            // A plain button has no logical range in the preparsed data --
            // both limits come back zero -- where a descriptor must state
            // one. Zero to one is what such a button had.
            if (cap.range.button.logical_min == 0 and cap.range.button.logical_max == 0) {
                try write(w, .global_logical_minimum, 0);
                try write(w, .global_logical_maximum, 1);
            } else {
                try write(w, .global_logical_minimum, cap.range.button.logical_min);
                try write(w, .global_logical_maximum, cap.range.button.logical_max);
            }

            try write(w, .global_report_size, cap.report_size);
            if (!cap.isRange()) {
                try write(w, .global_report_count, @as(i32, cap.report_count) + report_count);
            } else {
                try write(w, .global_report_count, cap.report_count);
            }

            // A button is one bit, so it has no physical limits or units.
            // Anything left over from a previous field has to be cleared.
            if (last_physical_min != 0) {
                last_physical_min = 0;
                try write(w, .global_physical_minimum, 0);
            }
            if (last_physical_max != 0) {
                last_physical_max = 0;
                try write(w, .global_physical_maximum, 0);
            }
            if (last_unit_exponent != 0) {
                last_unit_exponent = 0;
                try write(w, .global_unit_exponent, 0);
            }
            if (last_unit != 0) {
                last_unit = 0;
                try write(w, .global_unit, 0);
            }

            try writeMain(w, rt, cap.bit_field);
            report_count = 0;
            continue;
        }

        // A value.
        if (inhibit_usage) {
            inhibit_usage = false;
        } else {
            try writeUsage(w, cap);
        }
        try writeDesignatorAndString(w, cap);

        // A value *array* -- the main item's variable bit is clear -- states
        // its count as a span of data indices rather than in `report_count`.
        var effective_count: i32 = cap.report_count;
        if (cap.bit_field & 0x02 != 0x02) {
            effective_count = @as(i32, cap.usage.range.data_index_max) -
                @as(i32, cap.usage.range.data_index_min) + 1;
        }

        if (try runsInto(b, node, cap, rt, false)) {
            report_count += 1;
            continue;
        }

        try write(w, .global_logical_minimum, cap.range.not_button.logical_min);
        try write(w, .global_logical_maximum, cap.range.not_button.logical_max);

        if (last_physical_min != cap.range.not_button.physical_min or
            last_physical_max != cap.range.not_button.physical_max)
        {
            try write(w, .global_physical_minimum, cap.range.not_button.physical_min);
            last_physical_min = cap.range.not_button.physical_min;
            try write(w, .global_physical_maximum, cap.range.not_button.physical_max);
            last_physical_max = cap.range.not_button.physical_max;
        }
        if (last_unit_exponent != cap.units_exp) {
            try write(w, .global_unit_exponent, cap.units_exp);
            last_unit_exponent = cap.units_exp;
        }
        if (last_unit != cap.units) {
            try write(w, .global_unit, cap.units);
            last_unit = cap.units;
        }

        try write(w, .global_report_size, cap.report_size);
        try write(w, .global_report_count, effective_count + report_count);
        try writeMain(w, rt, cap.bit_field);
        report_count = 0;
    }
}

/// Whether the next node describes a field identical to this one in every
/// respect that a global item records, so that the two can share one main
/// item with a larger report count.
fn runsInto(b: *Builder, node: *Node, cap: Cap, rt: usize, button: bool) Error!bool {
    const next = node.next orelse return false;
    if (@intFromEnum(next.main_item_type) != rt) return false;
    if (next.type_of_node != .cap) return false;

    const other = try b.capAt(next.caps_index);
    if (other.isButtonCap() != button) return false;
    if (cap.isRange() or other.isRange()) return false;
    if (other.usage_page != cap.usage_page) return false;
    if (other.report_id != cap.report_id) return false;
    if (other.bit_field != cap.bit_field) return false;

    if (button) return true;

    if (other.range.not_button.logical_min != cap.range.not_button.logical_min) return false;
    if (other.range.not_button.logical_max != cap.range.not_button.logical_max) return false;
    if (other.range.not_button.physical_min != cap.range.not_button.physical_min) return false;
    if (other.range.not_button.physical_max != cap.range.not_button.physical_max) return false;
    if (other.units_exp != cap.units_exp) return false;
    if (other.units != cap.units) return false;
    if (other.report_size != cap.report_size) return false;
    if (other.report_count != 1 or cap.report_count != 1) return false;
    return true;
}

fn writeUsage(w: *item.Writer, cap: Cap) Error!void {
    if (cap.isRange()) {
        try write(w, .local_usage_minimum, cap.usage.range.usage_min);
        try write(w, .local_usage_maximum, cap.usage.range.usage_max);
    } else {
        try write(w, .local_usage, cap.usage.not_range.usage);
    }
}

/// The designator and string indices, which index the physical descriptor and
/// the USB string descriptor.
///
/// Index zero is skipped for both, and not as an optimisation: designator set
/// zero says how many further sets there are, and string index zero is the
/// list of supported languages, so neither can name a control.
fn writeDesignatorAndString(w: *item.Writer, cap: Cap) Error!void {
    if (cap.isDesignatorRange()) {
        try write(w, .local_designator_minimum, cap.usage.range.designator_min);
        try write(w, .local_designator_maximum, cap.usage.range.designator_max);
    } else if (cap.usage.not_range.designator_index != 0) {
        try write(w, .local_designator_index, cap.usage.not_range.designator_index);
    }

    if (cap.isStringRange()) {
        try write(w, .local_string_minimum, cap.usage.range.string_min);
        try write(w, .local_string_maximum, cap.usage.range.string_max);
    } else if (cap.usage.not_range.string_index != 0) {
        try write(w, .local_string, cap.usage.not_range.string_index);
    }
}

fn writeMain(w: *item.Writer, rt: usize, bits: u32) Error!void {
    const which: item.Item = switch (rt) {
        0 => .main_input,
        1 => .main_output,
        2 => .main_feature,
        else => return error.Unsupported,
    };
    try write(w, which, bits);
}

/// `item.Writer.write` with the value widened and its one error folded in.
///
/// A value the encoding cannot express means the blob said something a
/// descriptor cannot say, which is a blob this code cannot read.
fn write(w: *item.Writer, which: item.Item, value: anytype) Error!void {
    w.write(which, @intCast(value)) catch return error.Unsupported;
}

test {
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// Tests
//
// Windows is not needed for any of this. The preparsed blob is just a
// structure, so the tests below build one and put it through the whole
// reconstruction -- which is the only way this code gets exercised anywhere
// but on a Windows machine with the right device plugged in.
// ---------------------------------------------------------------------------

const Blob = struct {
    bytes: []align(4) u8,

    /// Build a blob with `cap_count` capabilities and `node_count`
    /// collections, laid out the way Windows lays one out.
    fn init(buf: []align(4) u8, cap_count: usize, node_count: usize) Blob {
        @memset(buf, 0);
        const self: Blob = .{ .bytes = buf };
        const head = self.header();
        @memcpy(&head.magic_key, preparsed.magic);
        head.first_byte_of_link_collection_array = @intCast(cap_count * @sizeOf(Cap));
        head.number_link_collection_nodes = @intCast(node_count);
        return self;
    }

    fn size(cap_count: usize, node_count: usize) usize {
        return 44 + cap_count * @sizeOf(Cap) + node_count * @sizeOf(LinkCollectionNode);
    }

    fn header(self: Blob) *preparsed.Header {
        return @ptrCast(@alignCast(self.bytes.ptr));
    }

    fn cap(self: Blob, index: usize) *Cap {
        const ptr: [*]Cap = @ptrCast(@alignCast(self.bytes.ptr + 44));
        return &ptr[index];
    }

    fn node(self: Blob, index: usize) *LinkCollectionNode {
        const start = 44 + self.header().first_byte_of_link_collection_array;
        const ptr: [*]LinkCollectionNode = @ptrCast(@alignCast(self.bytes.ptr + start));
        return &ptr[index];
    }
};

/// A device with one application collection and one four-byte input field.
fn buildSimpleMouse(buf: []align(4) u8) Blob {
    const blob: Blob = .init(buf, 1, 1);
    const head = blob.header();
    head.usage = 0x02; // Mouse
    head.usage_page = 0x01; // Generic Desktop
    head.caps_info[0] = .{
        .first_cap = 0,
        .number_of_caps = 1,
        .last_cap = 1,
        // One report ID byte plus four data bytes.
        .report_byte_length = 5,
    };

    const node = blob.node(0);
    node.link_usage = 0x02;
    node.link_usage_page = 0x01;
    node.bits = 0x01; // Application collection

    const cap = blob.cap(0);
    cap.usage_page = 0x01;
    cap.report_id = 0;
    cap.bit_position = 0;
    cap.report_size = 8;
    cap.report_count = 4;
    // Counts the report ID byte, which is why the reconstruction subtracts
    // one from it.
    cap.byte_position = 1;
    cap.bit_count = 32;
    cap.bit_field = 0x02; // Data, Variable, Absolute
    cap.link_collection = 0;
    cap.usage.not_range.usage = 0x30; // X
    cap.range.not_button = .{
        .has_null = 0,
        .reserved4 = @splat(0),
        .logical_min = 0,
        .logical_max = 255,
        .physical_min = 0,
        .physical_max = 0,
    };
    return blob;
}

test "a simple device reconstructs to the descriptor it must have had" {
    var blob_buf: [Blob.size(1, 1)]u8 align(4) = undefined;
    _ = buildSimpleMouse(&blob_buf);

    var scratch: [16 * 1024]u8 = undefined;
    var out: [256]u8 = undefined;
    const descriptor_bytes = try reconstruct(&blob_buf, &out, &scratch);

    try std.testing.expectEqualSlices(u8, &.{
        0x05, 0x01, // Usage Page (Generic Desktop)
        0x09, 0x02, // Usage (Mouse)
        0xA1, 0x01, // Collection (Application)
        0x09, 0x30, //   Usage (X)
        0x15, 0x00, //   Logical Minimum (0)
        0x26, 0xFF, 0x00, //   Logical Maximum (255)
        0x75, 0x08, //   Report Size (8)
        0x95, 0x04, //   Report Count (4)
        0x81, 0x02, //   Input (Data, Variable, Absolute)
        0xC0, // End Collection
    }, descriptor_bytes);
}

test "the reconstruction round trips through this library's own parser" {
    var blob_buf: [Blob.size(1, 1)]u8 align(4) = undefined;
    _ = buildSimpleMouse(&blob_buf);

    var scratch: [16 * 1024]u8 = undefined;
    var out: [256]u8 = undefined;
    const bytes = try reconstruct(&blob_buf, &out, &scratch);

    // The property that matters on a real device, where the original
    // descriptor is not around to compare against: what comes out has to
    // describe the device Windows said it was.
    const descriptor = @import("../../descriptor.zig");
    const usage = descriptor.firstUsage(bytes).?;
    try std.testing.expectEqual(@as(u16, 0x01), usage.page);
    try std.testing.expectEqual(@as(u16, 0x02), usage.id);
}

test "measuring agrees with writing" {
    var blob_buf: [Blob.size(1, 1)]u8 align(4) = undefined;
    _ = buildSimpleMouse(&blob_buf);

    var scratch: [16 * 1024]u8 = undefined;
    const len = try measure(&blob_buf, &scratch);

    var out: [256]u8 = undefined;
    const bytes = try reconstruct(&blob_buf, &out, &scratch);
    try std.testing.expectEqual(bytes.len, len);

    // And a buffer one byte short has to say so rather than truncate.
    try std.testing.expectError(
        error.BufferTooSmall,
        reconstruct(&blob_buf, out[0 .. len - 1], &scratch),
    );
}

test "a gap between fields becomes constant padding" {
    // Two input fields with four bits of nothing between them, which is
    // exactly what a descriptor's padding item was.
    var blob_buf: [Blob.size(2, 1)]u8 align(4) = undefined;
    const blob: Blob = .init(&blob_buf, 2, 1);
    blob.header().usage_page = 0x01;
    blob.header().caps_info[0] = .{
        .first_cap = 0,
        .number_of_caps = 2,
        .last_cap = 2,
        .report_byte_length = 3,
    };
    const node = blob.node(0);
    node.link_usage = 0x01;
    node.link_usage_page = 0x01;
    node.bits = 0x01;

    for (0..2) |i| {
        const cap = blob.cap(i);
        cap.usage_page = 0x01;
        cap.report_size = 4;
        cap.report_count = 1;
        cap.bit_field = 0x02;
        cap.link_collection = 0;
        cap.usage.not_range.usage = @intCast(0x30 + i);
        cap.range.not_button = .{
            .has_null = 0,
            .reserved4 = @splat(0),
            .logical_min = 0,
            .logical_max = 15,
            .physical_min = 0,
            .physical_max = 0,
        };
    }
    // Bits 0..3, then a gap of 4, then bits 8..11.
    blob.cap(0).byte_position = 1;
    blob.cap(0).bit_position = 0;
    blob.cap(1).byte_position = 2;
    blob.cap(1).bit_position = 0;

    var scratch: [16 * 1024]u8 = undefined;
    var out: [256]u8 = undefined;
    const bytes = try reconstruct(&blob_buf, &out, &scratch);

    // A constant input item -- 0x81 0x03 -- has to appear between the two
    // data items, or the second field would be read from the wrong bits.
    try std.testing.expect(std.mem.indexOf(u8, bytes, &.{ 0x81, 0x03 }) != null);

    const first_data = std.mem.indexOf(u8, bytes, &.{ 0x81, 0x02 }).?;
    const padding = std.mem.indexOf(u8, bytes, &.{ 0x81, 0x03 }).?;
    const second_data = std.mem.lastIndexOf(u8, bytes, &.{ 0x81, 0x02 }).?;
    try std.testing.expect(first_data < padding);
    try std.testing.expect(padding < second_data);
}

test "scratch that is too small is reported rather than overrun" {
    var blob_buf: [Blob.size(1, 1)]u8 align(4) = undefined;
    _ = buildSimpleMouse(&blob_buf);

    var tiny: [8]u8 = undefined;
    var out: [256]u8 = undefined;
    try std.testing.expectError(
        error.ScratchTooSmall,
        reconstruct(&blob_buf, &out, &tiny),
    );
}

test "a blob that is not preparsed data is refused" {
    var scratch: [16 * 1024]u8 = undefined;
    var out: [256]u8 = undefined;
    try std.testing.expectError(error.Unsupported, reconstruct("", &out, &scratch));
    try std.testing.expectError(error.Unsupported, reconstruct("not a blob at all!!", &out, &scratch));
}
