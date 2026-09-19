// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What names a HID device to the operating system, and the only thing
//! `Device.open` needs.
//!
//! The contents are the backend's business and no portable code should parse
//! them. What each one puts here:
//!
//! | Backend | Contents |
//! | --- | --- |
//! | Linux, FreeBSD | the device node path, `/dev/hidraw3` |
//! | macOS | the registry entry ID, `DevSrvsID:4294970234` |
//! | Windows | the device interface path, `\\?\HID#VID_046D&PID_C52B&...` |
//!
//! This is a value and not a slice, which is the whole point of it: an
//! identifier's actual job is to be remembered -- copied into a configuration
//! struct, printed, compared, read back off a command line -- and every one of
//! those is free on a value and needs a lifetime rule on a slice. It is also
//! what lets an ID outlive the `Enumerator` that produced it, which is the
//! normal way a program picks a device once and opens it later.
//!
//! None of the four backends survives a replug: the node number, the registry
//! entry ID and the interface path all change when hardware comes and goes.
//! Code that has to recognise the same physical device across a replug should
//! match on `DeviceInfo.serial_number`.

const DeviceId = @This();

const std = @import("std");

/// The longest identifier any backend produces.
///
/// The bound comes from Windows, which is far and away the longest: `\\?\`
/// plus a device instance ID, which `MAX_DEVICE_ID_LEN` caps at 200
/// characters, plus `#` and a 38 character GUID, so about 243. Device
/// interface paths use a restricted character set that encodes to one byte
/// per UTF-16 unit, so that is 243 bytes and not three times as many. This is
/// that bound doubled, which absorbs a nonconforming bus driver without
/// reaching for a heap.
pub const max_len = 512;

bytes: [max_len]u8,
len: u16,

/// An ID naming nothing, which `Device.open` rejects with
/// `error.DeviceNotFound`.
pub const none: DeviceId = .{ .bytes = undefined, .len = 0 };

/// Build an ID from bytes a backend produced.
pub fn init(text: []const u8) error{DeviceIdTooLong}!DeviceId {
    if (text.len > max_len) return error.DeviceIdTooLong;
    var self: DeviceId = .{ .bytes = undefined, .len = @intCast(text.len) };
    @memcpy(self.bytes[0..text.len], text);
    return self;
}

/// The identifier, aliasing `self`. Valid as long as the `DeviceId` is.
pub fn slice(self: *const DeviceId) []const u8 {
    return self.bytes[0..self.len];
}

/// Whether two IDs name the same device.
///
/// Byte equality, because every backend produces its IDs one way and there is
/// no case folding or normalisation that would be correct on all four. Two IDs
/// from different enumerations of an unchanged system compare equal.
pub fn eql(a: *const DeviceId, b: *const DeviceId) bool {
    return std.mem.eql(u8, a.slice(), b.slice());
}

/// Print the identifier as the backend spelled it, so that what a program logs
/// is what `parse` accepts back.
pub fn format(self: *const DeviceId, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(self.slice());
}

/// Read back an identifier that was printed or stored.
///
/// Nothing is validated beyond the length: whether the device still exists,
/// and whether the string was ever an identifier on this system at all, are
/// questions only `Device.open` can answer.
pub fn parse(text: []const u8) error{DeviceIdTooLong}!DeviceId {
    return init(text);
}

test "round trips through format and parse" {
    const original: DeviceId = try .init("/dev/hidraw3");

    var buf: [max_len]u8 = undefined;
    const printed = try std.fmt.bufPrint(&buf, "{f}", .{&original});
    try std.testing.expectEqualStrings("/dev/hidraw3", printed);

    const parsed: DeviceId = try .parse(printed);
    try std.testing.expect(original.eql(&parsed));
}

test "a Windows interface path fits with room to spare" {
    // A real one, from a Logitech receiver. The longest field is the instance
    // ID in the middle, which is what `max_len` is sized against.
    const path = "\\\\?\\HID#VID_046D&PID_C52B&MI_01&Col01#8&1e78b1e2&0&0000" ++
        "#{4d1e55b2-f16f-11cf-88cb-001111000030}";
    const id: DeviceId = try .init(path);
    try std.testing.expectEqualStrings(path, id.slice());
    try std.testing.expect(id.len < max_len / 2);
}

test "too long is an error rather than a truncation" {
    const long = "x" ** (max_len + 1);
    try std.testing.expectError(error.DeviceIdTooLong, DeviceId.init(long));
}

test "the empty id compares unequal to a real one" {
    const real: DeviceId = try .init("/dev/hidraw0");
    try std.testing.expect(!none.eql(&real));
    try std.testing.expectEqual(@as(usize, 0), none.slice().len);
}

test {
    std.testing.refAllDecls(@This());
}
