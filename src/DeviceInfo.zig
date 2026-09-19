// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Everything known about a HID device without talking to it.
//!
//! An `Enumerator` fills one of these per device; `Device.getInfo` fills one
//! for a device that is already open. It is a plain value with no allocation
//! and no lifetime behind it, so it can be copied, kept and compared freely.
//! That is why the strings are inline `Str` fields rather than slices, and why
//! `id` is a `DeviceId` rather than a pointer into the enumerator.
//!
//! Not every backend can answer every field, and the ones that cannot say so
//! rather than guessing:
//!
//! | Field | Linux | FreeBSD | Windows | macOS |
//! | --- | --- | --- | --- | --- |
//! | `manufacturer` | USB only | never | yes | yes |
//! | `product` | yes | yes | yes | yes |
//! | `serial_number` | yes | yes | yes | yes |
//! | `physical_location` | yes | yes | the interface path | the location ID |
//! | `interface_number` | USB only | never | composite devices | never |
//! | `release_number` | USB only | yes | yes | yes |
//!
//! On Linux `manufacturer` is `null` for anything that is not USB, because the
//! kernel reports only one combined name for such devices -- `HID_NAME`, which
//! this library puts in `product`. It is tempting to split that name on its
//! first space and call the halves manufacturer and product, and it is wrong:
//! the kernel joins the two USB strings with a space and there is no delimiter
//! left to recover. "Logitech G703 LIGHTSPEED" splits correctly by luck and
//! "ITE Tech. Inc. ITE Device(8595)" does not.

const DeviceInfo = @This();

const std = @import("std");

const BusType = @import("bus_type.zig").BusType;
const DeviceId = @import("DeviceId.zig");
const Str = @import("Str.zig");

/// What `Device.open` needs in order to open this device.
id: DeviceId,

/// The vendor ID (VID).
vendor_id: u16,

/// The product ID (PID).
product_id: u16,

/// The device release number -- `bcdDevice` on USB. Zero when the transport
/// carries none, or when the backend could not read it.
release_number: u16,

/// The usage page of the device's first top-level collection, and the usage
/// within it. Together these say what the device is for: `0x01`/`0x06` is a
/// keyboard, `0x01`/`0x02` a mouse, and anything on page `0xFF00` and above is
/// vendor defined.
///
/// Both are zero when the backend could not determine them, which happens when
/// `Enumerator.Options.usages` was false and on a device whose report
/// descriptor declares no collection.
usage_page: u16,
usage: u16,

/// The USB interface this HID function sits on, for a composite device.
///
/// `null` on every non-USB transport, and on USB when the backend cannot tell.
interface_number: ?u8,

/// How the device is attached.
bus_type: BusType,

/// What the operating system called the bus before `bus_type` mapped it: a
/// `BUS_*` value from `input.h` on Linux and FreeBSD, and zero elsewhere,
/// since neither Windows nor macOS reports a number.
///
/// Here so that mapping into a portable enum loses nothing. A caller that
/// needs to tell `BUS_I8042` from `BUS_RMI`, both of which are `other`, can.
native_bus: u16,

/// Who made the device.
manufacturer: Str,

/// What the device calls itself.
product: Str,

/// An identifier meant to be unique to this individual device: the USB serial
/// number string, or the Bluetooth hardware address.
///
/// The only field that survives a replug, and so the only sound way to
/// recognise the same physical device in a later run. Most USB devices report
/// none.
serial_number: Str,

/// Where the device is attached: the path through the controller, hubs and
/// ports on USB, and the hardware address on Bluetooth. The exact spelling is
/// the operating system's and differs between them.
///
/// Stable across replugs of whatever is in that port, where `serial_number` is
/// stable across replugs of the device, which is the opposite question.
physical_location: Str,

/// A `DeviceInfo` describing nothing, which every backend starts from so that
/// a field it cannot answer is left saying so.
pub const empty: DeviceInfo = .{
    .id = .none,
    .vendor_id = 0,
    .product_id = 0,
    .release_number = 0,
    .usage_page = 0,
    .usage = 0,
    .interface_number = null,
    .bus_type = .unknown,
    .native_bus = 0,
    .manufacturer = .empty,
    .product = .empty,
    .serial_number = .empty,
    .physical_location = .empty,
};

/// Whether this device matches a vendor and product filter, either half of
/// which may be `null` for "any".
pub fn matches(self: *const DeviceInfo, vendor_id: ?u16, product_id: ?u16) bool {
    if (vendor_id) |v| if (self.vendor_id != v) return false;
    if (product_id) |p| if (self.product_id != p) return false;
    return true;
}

/// One line naming the device, in the shape a program would log:
/// `046d:c52b [USB] Logitech USB Receiver`.
pub fn format(self: *const DeviceInfo, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{x:0>4}:{x:0>4} [{f}]", .{ self.vendor_id, self.product_id, self.bus_type });
    if (self.manufacturer.slice()) |m| try w.print(" {s}", .{m});
    if (self.product.slice()) |p| try w.print(" {s}", .{p});
    if (self.serial_number.slice()) |s| try w.print(" ({s})", .{s});
}

test "the empty info reports nothing rather than zeroes that look like answers" {
    try std.testing.expectEqual(@as(?[]const u8, null), empty.manufacturer.slice());
    try std.testing.expectEqual(@as(?u8, null), empty.interface_number);
    try std.testing.expectEqual(BusType.unknown, empty.bus_type);
    try std.testing.expectEqual(@as(usize, 0), empty.id.slice().len);
}

test "matches treats null as any" {
    var info: DeviceInfo = .empty;
    info.vendor_id = 0x046d;
    info.product_id = 0xc52b;

    try std.testing.expect(info.matches(null, null));
    try std.testing.expect(info.matches(0x046d, null));
    try std.testing.expect(info.matches(null, 0xc52b));
    try std.testing.expect(info.matches(0x046d, 0xc52b));
    try std.testing.expect(!info.matches(0x046d, 0x0001));
    try std.testing.expect(!info.matches(0x1234, null));
}

test "format omits the strings a device does not report" {
    var info: DeviceInfo = .empty;
    info.vendor_id = 0x046d;
    info.product_id = 0xc52b;
    info.bus_type = .usb;
    info.product = .init("USB Receiver");

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "046d:c52b [USB] USB Receiver",
        try std.fmt.bufPrint(&buf, "{f}", .{&info}),
    );

    info.manufacturer = .init("Logitech");
    info.serial_number = .init("A1B2C3");
    try std.testing.expectEqualStrings(
        "046d:c52b [USB] Logitech USB Receiver (A1B2C3)",
        try std.fmt.bufPrint(&buf, "{f}", .{&info}),
    );
}

test {
    std.testing.refAllDecls(@This());
}
