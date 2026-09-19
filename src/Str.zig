// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A short string a device reported about itself, held by value.
//!
//! `DeviceInfo` carries four of these -- manufacturer, product, serial number
//! and physical location -- and holding them inline rather than as slices is
//! what lets a `DeviceInfo` be copied, stashed and compared with no lifetime
//! attached to it and no `deinit` in the caller's way.
//!
//! The distinction the type exists to make is between a device that reports
//! nothing and a string that would not fit. `slice` returns `null` for the
//! first and `truncated` is set for the second, which matters to a caller
//! matching on a serial number: an absent serial and a serial whose first 255
//! bytes happen to match are not the same answer.

const Str = @This();

const std = @import("std");

/// The longest string kept.
///
/// A USB string descriptor is at most 255 bytes, which is 126 UTF-16 code
/// units, which is 126 bytes of UTF-8 for anything on a real device. Linux
/// keeps `HID_NAME` in the kernel's 128 byte `hid_device::name` and `HID_UNIQ`
/// in a 64 byte field, and FreeBSD's `hdi_name` and `hdi_uniq` are the same
/// two sizes. 256 covers all of that with headroom, and `truncated` tells the
/// truth in the case it does not.
pub const max_len = 256;

bytes: [max_len]u8,
len: u16,
/// The system reported a longer string than `bytes` holds.
truncated: bool,

/// A string the device does not report.
pub const empty: Str = .{ .bytes = undefined, .len = 0, .truncated = false };

/// Keep as much of `text` as fits, recording whether anything was dropped.
///
/// Truncating rather than failing is deliberate: a product name too long to
/// keep is not a reason to refuse to report the device's vendor ID, and a
/// caller that cares can look at `truncated`.
pub fn init(text: []const u8) Str {
    const keep = @min(text.len, max_len);
    var self: Str = .{
        .bytes = undefined,
        .len = @intCast(keep),
        .truncated = text.len > max_len,
    };
    @memcpy(self.bytes[0..keep], text[0..keep]);
    return self;
}

/// The string, aliasing `self`, or `null` when the device reports none.
///
/// `null` rather than `""` because the two are different facts and a caller
/// printing a placeholder wants to know which it has. A device that reports an
/// empty string is indistinguishable from one that reports none, which is a
/// limit of every transport here and not of this type.
pub fn slice(self: *const Str) ?[]const u8 {
    return if (self.len == 0) null else self.bytes[0..self.len];
}

/// Print the string, or nothing at all when there is none.
pub fn format(self: *const Str, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(self.slice() orelse "");
}

/// Whether this is the string `text`. A `Str` reporting nothing matches
/// nothing, including the empty string.
pub fn eqlSlice(self: *const Str, text: []const u8) bool {
    const got = self.slice() orelse return false;
    return std.mem.eql(u8, got, text);
}

test "an absent string is not an empty one" {
    try std.testing.expectEqual(@as(?[]const u8, null), empty.slice());
    try std.testing.expect(!empty.eqlSlice(""));

    const present: Str = .init("Logitech");
    try std.testing.expectEqualStrings("Logitech", present.slice().?);
    try std.testing.expect(present.eqlSlice("Logitech"));
    try std.testing.expect(!present.eqlSlice("logitech"));
}

test "truncation is recorded rather than hidden" {
    const short: Str = .init("abc");
    try std.testing.expect(!short.truncated);

    const long: Str = .init("x" ** (max_len + 10));
    try std.testing.expect(long.truncated);
    try std.testing.expectEqual(@as(usize, max_len), long.slice().?.len);

    // Exactly the limit is not truncation.
    const exact: Str = .init("y" ** max_len);
    try std.testing.expect(!exact.truncated);
}

test {
    std.testing.refAllDecls(@This());
}
