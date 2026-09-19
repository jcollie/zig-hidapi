// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Everything the Linux backend learns about a device without opening it.
//!
//! `/sys/class/hidraw/hidrawN/` is world readable, so enumerating this way
//! works for an unprivileged process, which asking the device does not: the
//! node itself is root-only until a udev rule says otherwise. That is the
//! whole reason enumeration goes through sysfs rather than through the ioctls
//! it mirrors.
//!
//! It mirrors them exactly. `device/uevent` carries `HID_ID`, `HID_NAME`,
//! `HID_PHYS` and `HID_UNIQ`, which are the same four facts `HIDIOCGRAWINFO`,
//! `HIDIOCGRAWNAME`, `HIDIOCGRAWPHYS` and `HIDIOCGRAWUNIQ` answer, and
//! `device/report_descriptor` is what `HIDIOCGRDESC` copies out.
//!
//! The manufacturer, product and serial strings are not in `uevent` and are
//! not HID facts at all -- they belong to the USB device the HID function sits
//! on, a couple of levels up the device tree. This is the walk libudev's
//! `get_parent_with_subsystem_devtype` performs, reached without libudev and
//! without an allocator: `..` resolves *through* the `device` symlink, so
//! `device/../../manufacturer` names the `usb_device` with no `readlink` and
//! no path arithmetic.

const std = @import("std");

/// Where the class directory lives. Taken as a constant rather than found, so
/// that a test can point the reader at a fixture tree instead.
pub const class_path = "/sys/class/hidraw";

/// The `BUS_*` value for USB, from `uapi/linux/input.h`. Only a USB device has
/// the ancestors the string walk below looks for.
const bus_usb = 0x03;

/// The fields of `device/uevent` this library reads, aliasing the text they
/// were parsed out of.
pub const Uevent = struct {
    /// A `BUS_*` value. Zero when `HID_ID` was absent or unparsable, which is
    /// not a value the kernel ever reports.
    bus: u16 = 0,
    vendor: u16 = 0,
    product: u16 = 0,
    /// The vendor and product strings run together, which is what
    /// `HIDIOCGRAWNAME` answers.
    name: []const u8 = "",
    phys: []const u8 = "",
    uniq: []const u8 = "",
};

/// Parse the `key=value` lines of a `uevent` file.
///
/// Keys this library does not use are skipped, and a malformed `HID_ID` is
/// left as zero rather than treated as an error: the device is still worth
/// reporting, and `bus == 0` is already the "did not say" value.
pub fn parseUevent(text: []const u8) Uevent {
    var result: Uevent = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "HID_ID")) {
            parseHidId(value, &result);
        } else if (std.mem.eql(u8, key, "HID_NAME")) {
            result.name = value;
        } else if (std.mem.eql(u8, key, "HID_PHYS")) {
            result.phys = value;
        } else if (std.mem.eql(u8, key, "HID_UNIQ")) {
            result.uniq = value;
        }
    }
    return result;
}

/// `HID_ID=0003:0000048D:00008297` -- bus, vendor and product in hex,
/// colon separated, zero padded to widths that are not worth relying on.
fn parseHidId(value: []const u8, out: *Uevent) void {
    var parts = std.mem.splitScalar(u8, value, ':');
    const bus = parts.next() orelse return;
    const vendor = parts.next() orelse return;
    const product = parts.next() orelse return;
    // A field too wide for its type is a kernel this library does not
    // understand, so leave the lot at zero rather than keep half of it.
    // The vendor and product fields are written eight hex digits wide even
    // though the values are 16 bit, so they have to be parsed wide and then
    // narrowed. Narrowing after validating, rather than parsing straight into
    // a `u16`, is also what keeps a malformed line an error instead of a
    // panic.
    const b = std.fmt.parseInt(u32, bus, 16) catch return;
    const v = std.fmt.parseInt(u32, vendor, 16) catch return;
    const p = std.fmt.parseInt(u32, product, 16) catch return;
    out.bus = std.math.cast(u16, b) orelse return;
    out.vendor = std.math.cast(u16, v) orelse return;
    out.product = std.math.cast(u16, p) orelse return;
}

/// Read a sysfs attribute and strip the newline the kernel appends.
///
/// Returns `null` when the attribute does not exist, which is the ordinary
/// answer for `serial` on a device without one and for every USB attribute on
/// a device that is not USB, and so is not treated as a failure.
pub fn readAttribute(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buf: []u8,
) std.Io.Cancelable!?[]const u8 {
    const bytes = dir.readFile(io, sub_path, buf) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // Anything else -- absent, unreadable, a directory, gone between the
        // listing and the read -- means this attribute has no value to report.
        else => return null,
    };
    const trimmed = std.mem.trimEnd(u8, bytes, "\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Whether the device behind `node` sits on USB, and so has the ancestors
/// `usbAttribute` looks for.
pub fn isUsb(uevent: Uevent) bool {
    return uevent.bus == bus_usb;
}

/// Read an attribute of the `usb_device` two levels above the HID device.
///
/// `sub_path` is one of `manufacturer`, `product`, `serial` or `bcdDevice`.
/// The caller has to have checked `isUsb` first: on any other transport these
/// parents belong to some other subsystem and the files are simply absent, so
/// the result would be `null` anyway, but only by accident.
pub fn usbAttribute(
    io: std.Io,
    class_dir: std.Io.Dir,
    node: []const u8,
    comptime sub_path: []const u8,
    buf: []u8,
) std.Io.Cancelable!?[]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/device/../../" ++ sub_path,
        .{node},
    ) catch return null;
    return readAttribute(io, class_dir, path, buf);
}

/// Read the USB interface number, which lives one level up rather than two:
/// `device/..` is the `usb_interface`, `device/../..` the `usb_device`.
pub fn usbInterfaceNumber(
    io: std.Io,
    class_dir: std.Io.Dir,
    node: []const u8,
) std.Io.Cancelable!?u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/device/../bInterfaceNumber", .{node}) catch
        return null;
    var buf: [16]u8 = undefined;
    const text = try readAttribute(io, class_dir, path, &buf) orelse return null;
    return std.fmt.parseInt(u8, text, 16) catch null;
}

test "a USB mouse's uevent" {
    const text =
        \\DRIVER=hid-generic
        \\HID_ID=0003:0000048D:00008297
        \\HID_NAME=ITE Tech. Inc. ITE Device(8595)
        \\HID_PHYS=usb-0000:06:00.1-4/input0
        \\HID_UNIQ=
        \\MODALIAS=hid:b0003g0001v0000048Dp00008297
        \\
    ;
    const u = parseUevent(text);
    try std.testing.expectEqual(@as(u16, 0x0003), u.bus);
    try std.testing.expectEqual(@as(u16, 0x048D), u.vendor);
    try std.testing.expectEqual(@as(u16, 0x8297), u.product);
    try std.testing.expectEqualStrings("ITE Tech. Inc. ITE Device(8595)", u.name);
    try std.testing.expectEqualStrings("usb-0000:06:00.1-4/input0", u.phys);
    // An empty HID_UNIQ is the common case for USB, and is how the kernel
    // says the device reports no serial number.
    try std.testing.expectEqualStrings("", u.uniq);
    try std.testing.expect(isUsb(u));
}

test "a Bluetooth device seeds HID_UNIQ from the hardware address" {
    const text =
        \\HID_ID=0005:0000054C:000009CC
        \\HID_NAME=Wireless Controller
        \\HID_PHYS=00:1a:7d:da:71:13
        \\HID_UNIQ=a0:ab:51:33:cd:ef
        \\
    ;
    const u = parseUevent(text);
    try std.testing.expectEqual(@as(u16, 0x0005), u.bus);
    try std.testing.expectEqualStrings("a0:ab:51:33:cd:ef", u.uniq);
    // Not USB, so the manufacturer walk must not be attempted: `..` there is
    // a Bluetooth device, and reading `manufacturer` off it would be a
    // different device's answer if it ever had one.
    try std.testing.expect(!isUsb(u));
}

test "a missing or malformed HID_ID leaves the identity at zero" {
    try std.testing.expectEqual(@as(u16, 0), parseUevent("HID_NAME=x\n").bus);
    try std.testing.expectEqual(@as(u16, 0), parseUevent("HID_ID=nonsense\n").bus);
    // Two fields where three are wanted: keep none of them rather than half.
    const half = parseUevent("HID_ID=0003:0000048D\n");
    try std.testing.expectEqual(@as(u16, 0), half.bus);
    try std.testing.expectEqual(@as(u16, 0), half.vendor);
}

test "a value containing an equals sign survives" {
    // MODALIAS does not, but a product name could, and splitting on the last
    // separator rather than the first is a classic way to lose one.
    const u = parseUevent("HID_NAME=Foo = Bar\n");
    try std.testing.expectEqualStrings("Foo = Bar", u.name);
}

test {
    std.testing.refAllDecls(@This());
}
