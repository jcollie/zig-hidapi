// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const Descriptor = @This();
const std = @import("std");

const log = std.log.scoped(.descriptor);

pub const Prefix = packed struct(u8) {
    b_size: u2,
    b_type: u2,
    b_tag: u4,
};

pub fn parse(data: []const u8) void {
    if (data.len == 0) return;
    const prefix: Prefix = data[0];
    log.warn("{d} {d} {d}", .{ prefix.b_size, prefix.b_type, prefix.b_tag });
}
