// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! How a macOS device is named, and what its transport string means.
//!
//! Separate from `darwin.zig` because none of it is IOKit: it is string and
//! number work that happens to be about macOS. Keeping it apart means these
//! tests run on whatever machine the suite runs on rather than only on a Mac,
//! which for a backend nobody here can execute is the only coverage there is.

const std = @import("std");

const BusType = @import("../../bus_type.zig").BusType;
const iokit_transport = struct {
    // Repeated rather than imported: `iokit.zig` declares Mach types that do
    // not exist off Darwin, and this file is meant to compile anywhere.
    const usb = "USB";
    const bluetooth = "Bluetooth";
    const i2c = "I2C";
    const spi = "SPI";
};

/// How a device ID is spelled here: the registry entry ID, decimal, behind a
/// prefix.
///
/// The same spelling the C hidapi uses, so an ID written down by one library
/// is understood by the other. The entry ID does not survive a replug --
/// unplugging destroys the registry object and replugging makes a new one with
/// a new ID -- which is true of every backend's ID and is why
/// `DeviceInfo.serial_number` is the field to match on across runs.
const id_prefix = "DevSrvsID:";

pub fn formatId(entry_id: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, id_prefix ++ "{d}", .{entry_id}) catch null;
}

pub fn parseId(id: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, id, id_prefix)) return null;
    return std.fmt.parseInt(u64, id[id_prefix.len..], 10) catch null;
}

/// The transport a `kIOHIDTransportKey` value names.
///
/// Prefix-matched and case-insensitive on purpose: `"Bluetooth"` and
/// `"BluetoothLowEnergy"` are both Bluetooth as far as a HID conversation is
/// concerned, and the exact spellings are not documented anywhere this
/// library can check them.
pub fn busTypeFromTransport(transport: []const u8) BusType {
    if (std.ascii.startsWithIgnoreCase(transport, iokit_transport.bluetooth)) return .bluetooth;
    if (std.ascii.eqlIgnoreCase(transport, iokit_transport.usb)) return .usb;
    if (std.ascii.eqlIgnoreCase(transport, iokit_transport.i2c)) return .i2c;
    if (std.ascii.eqlIgnoreCase(transport, iokit_transport.spi)) return .spi;
    if (std.ascii.eqlIgnoreCase(transport, "Virtual")) return .virtual;
    return if (transport.len == 0) .unknown else .other;
}

test "a device id round trips through the hidapi spelling" {
    var buf: [64]u8 = undefined;
    const text = formatId(4294970234, &buf).?;
    try std.testing.expectEqualStrings("DevSrvsID:4294970234", text);
    try std.testing.expectEqual(@as(?u64, 4294970234), parseId(text));
}

test "an id that is not one of ours is refused rather than guessed at" {
    try std.testing.expectEqual(@as(?u64, null), parseId("/dev/hidraw0"));
    try std.testing.expectEqual(@as(?u64, null), parseId("DevSrvsID:"));
    try std.testing.expectEqual(@as(?u64, null), parseId("DevSrvsID:not-a-number"));
}

test "transport strings map onto the portable bus types" {
    try std.testing.expectEqual(BusType.usb, busTypeFromTransport("USB"));
    try std.testing.expectEqual(BusType.bluetooth, busTypeFromTransport("Bluetooth"));
    // Both Bluetooth spellings, which is why the match is a prefix.
    try std.testing.expectEqual(BusType.bluetooth, busTypeFromTransport("BluetoothLowEnergy"));
    try std.testing.expectEqual(BusType.i2c, busTypeFromTransport("I2C"));
    try std.testing.expectEqual(BusType.spi, busTypeFromTransport("SPI"));
    try std.testing.expectEqual(BusType.unknown, busTypeFromTransport(""));
    try std.testing.expectEqual(BusType.other, busTypeFromTransport("Something Else"));
}

test {
    std.testing.refAllDecls(@This());
}
