// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! `hidinfo` -- list the HID devices attached to this machine and say what
//! they contain.
//!
//! Roughly what `lsusb -v` is for USB, for HID: every device the system knows
//! about, what it calls itself, and -- for the ones this process is allowed to
//! open -- its report descriptor and the fields that descriptor describes.
//!
//! It is also the library's own worked example. Everything it does is
//! something a dependent will want to do: enumerate, filter, open, read a
//! descriptor, parse it, and make sense of the result. If something here is
//! awkward, that is a fault in the library rather than in this program.
//!
//! Enumeration needs no permissions, so the listing is always complete.
//! Opening a device does, so on a machine without a udev rule most devices
//! will list and then report that they cannot be opened -- which is the
//! library's behaviour, shown rather than hidden.

const std = @import("std");
const hidapi = @import("hidapi");

const usage_text =
    \\usage: hidinfo [options]
    \\
    \\Lists the HID devices attached to this machine.
    \\
    \\  -v, --vendor <hex>    only devices with this vendor ID, e.g. 046d
    \\  -p, --product <hex>   only devices with this product ID
    \\  -u, --usage <hex>     only devices whose usage page is this
    \\  -s, --short           one line per device; do not open anything
    \\  -r, --raw             also dump the report descriptor as hex
    \\  -h, --help            this
    \\
    \\Enumeration needs no permissions. Opening a device does: on Linux and
    \\FreeBSD the device nodes are root-only until a udev or devd rule says
    \\otherwise, and on macOS the process needs Input Monitoring. Without
    \\that, devices are listed and then reported as inaccessible.
    \\
;

const Options = struct {
    vendor_id: ?u16 = null,
    product_id: ?u16 = null,
    usage_page: ?u16 = null,
    short: bool = false,
    raw: bool = false,
};

comptime {
    // `zig build check` compiles this as an *object*, which has no start code
    // to reference `main` -- and Zig analyzes lazily, so without this the
    // whole program would compile to nothing and say nothing about whether it
    // builds for the other three systems.
    _ = &main;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var options: Options = .{};
    {
        var args = try init.minimal.args.iterateAllocator(init.gpa);
        defer args.deinit();
        _ = args.next(); // the program's own name

        while (args.next()) |arg| {
            if (eq(arg, "-h", "--help")) {
                try write(io, usage_text);
                return 0;
            } else if (eq(arg, "-s", "--short")) {
                options.short = true;
            } else if (eq(arg, "-r", "--raw")) {
                options.raw = true;
            } else if (eq(arg, "-v", "--vendor")) {
                options.vendor_id = parseHex(args.next()) orelse return badArg(io, arg);
            } else if (eq(arg, "-p", "--product")) {
                options.product_id = parseHex(args.next()) orelse return badArg(io, arg);
            } else if (eq(arg, "-u", "--usage")) {
                options.usage_page = parseHex(args.next()) orelse return badArg(io, arg);
            } else {
                try print(io, "hidinfo: unrecognised argument '{s}'\n\n", .{arg});
                try write(io, usage_text);
                return 2;
            }
        }
    }

    var out_buf: [8 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;

    var scratch: [hidapi.Enumerator.recommended_scratch]u8 = undefined;
    var devices: hidapi.Enumerator = undefined;
    try devices.init(io, &scratch, .{
        .vendor_id = options.vendor_id,
        .product_id = options.product_id,
    });
    defer devices.deinit(io);

    var seen: usize = 0;
    var opened: usize = 0;
    while (try devices.next(io)) |info| {
        // The enumerator filters on vendor and product; anything else is this
        // program's own business.
        if (options.usage_page) |page| {
            if (info.usage_page != page) continue;
        }
        seen += 1;

        if (options.short) {
            try w.print("{f}  {f}\n", .{ &info.id, info });
            continue;
        }

        if (seen > 1) try w.writeAll("\n");
        try describe(w, info);
        if (try inspect(io, w, info, options)) opened += 1;
    }

    if (seen == 0) {
        try w.writeAll("no HID devices found\n");
    } else if (!options.short) {
        try w.print("\n{d} device{s}, {d} opened\n", .{
            seen,
            if (seen == 1) "" else "s",
            opened,
        });
    }
    try w.flush();
    return 0;
}

/// Everything enumeration knows, which needed no permissions to learn.
fn describe(w: *std.Io.Writer, info: *const hidapi.DeviceInfo) !void {
    // `DeviceInfo.format` already leads with the vendor and product IDs.
    try w.print("{f}\n", .{info});
    try w.print("  id             {f}\n", .{&info.id});
    try w.print("  bus            {f}\n", .{info.bus_type});

    if (info.usage_page != 0 or info.usage != 0) {
        try w.print("  usage          {x:0>4}:{x:0>4}", .{ info.usage_page, info.usage });
        if (usageName(info.usage_page, info.usage)) |name| try w.print("  ({s})", .{name});
        try w.writeAll("\n");
    }
    if (info.interface_number) |n| try w.print("  interface      {d}\n", .{n});
    if (info.release_number != 0) {
        // bcdDevice: two binary-coded decimal digits either side of the point.
        try w.print("  release        {x:0>2}.{x:0>2}\n", .{
            info.release_number >> 8,
            info.release_number & 0xff,
        });
    }
    if (info.physical_location.slice()) |where| {
        // On Windows the physical location *is* the interface path, which is
        // already printed as the id, and repeating it gains nothing.
        if (!std.mem.eql(u8, where, info.id.slice())) {
            try w.print("  location       {s}\n", .{where});
        }
    }
}

/// Open the device and say what its reports contain.
///
/// Returns whether it could be opened. A device this process may not open is
/// reported and stepped over, because on a machine without a udev rule that is
/// most of them and is not an error.
fn inspect(
    io: std.Io,
    w: *std.Io.Writer,
    info: *const hidapi.DeviceInfo,
    options: Options,
) !bool {
    var descriptor_scratch: [hidapi.Device.recommended_descriptor_scratch]u8 = undefined;
    var device: hidapi.Device = undefined;
    device.open(io, info.id, .{ .descriptor_scratch = &descriptor_scratch }) catch |err| {
        try w.print("  (cannot open: {s})\n", .{@errorName(err)});
        return false;
    };
    defer device.close(io);

    var buf: [hidapi.max_report_descriptor_len]u8 = undefined;
    const len = device.getReportDescriptorLen(io) catch |err| {
        try w.print("  (no report descriptor: {s})\n", .{@errorName(err)});
        return true;
    };
    const bytes = device.getReportDescriptor(io, buf[0..len]) catch |err| {
        try w.print("  (no report descriptor: {s})\n", .{@errorName(err)});
        return true;
    };

    try w.print("  descriptor     {d} bytes\n", .{bytes.len});
    if (options.raw) try hexDump(w, bytes);
    try fields(w, bytes);
    return true;
}

/// The parsed fields, grouped the way the reports are.
fn fields(w: *std.Io.Writer, bytes: []const u8) !void {
    var parser: hidapi.descriptor.Parser = .init(bytes);
    var last_key: ?u32 = null;

    while (parser.next() catch |err| {
        try w.print("  (descriptor does not parse: {s})\n", .{@errorName(err)});
        return;
    }) |field| {
        // One heading per report, since a device's reports are laid out
        // independently of each other.
        const key = (@as(u32, @intFromEnum(field.kind)) << 8) | field.report_id;
        if (last_key != key) {
            last_key = key;
            try w.print("  {f} report", .{field.kind});
            if (field.report_id != 0) try w.print(" {d}", .{field.report_id});
            try w.writeAll("\n");
        }

        try w.print("    {d:>4}..{d:<4} {d:>2}x{d:<3} [{f}]", .{
            field.bit_offset,
            field.bit_offset + field.totalBits() - 1,
            field.count,
            field.bit_size,
            field.flags,
        });

        if (field.logical_min != field.logical_max) {
            try w.print(" {d}..{d}", .{ field.logical_min, field.logical_max });
        }

        // A constant field is padding and has nothing to name.
        if (!field.flags.constant) {
            switch (field.usages) {
                .none => {},
                .range => |r| try w.print("  usage {x:0>4}:{x:0>4}..{x:0>4}", .{
                    @as(u16, @truncate(r.min >> 16)),
                    @as(u16, @truncate(r.min)),
                    @as(u16, @truncate(r.max)),
                }),
                .list => |list| {
                    try w.writeAll("  usage");
                    for (list, 0..) |u, i| {
                        if (i == 4) {
                            try w.print(" +{d} more", .{list.len - i});
                            break;
                        }
                        try w.print(" {x:0>4}:{x:0>4}", .{
                            @as(u16, @truncate(u >> 16)),
                            @as(u16, @truncate(u)),
                        });
                    }
                },
            }
            if (field.usageAt(0)) |u| {
                if (usageName(@truncate(u >> 16), @truncate(u))) |name| {
                    try w.print("  ({s})", .{name});
                }
            }
        }
        try w.writeAll("\n");
    }
}

fn hexDump(w: *std.Io.Writer, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 16) {
        const line = bytes[offset..@min(offset + 16, bytes.len)];
        try w.print("    {x:0>4} ", .{offset});
        for (line) |b| try w.print(" {x:0>2}", .{b});
        try w.writeAll("\n");
    }
}

/// Names for the handful of usages worth recognising on sight.
///
/// Deliberately not a table of the whole HID usage tables, which are large,
/// revised regularly, and somebody else's data. This is enough to tell a
/// keyboard from a mouse at a glance.
fn usageName(page: u16, usage: u16) ?[]const u8 {
    return switch (page) {
        0x01 => switch (usage) { // Generic Desktop
            0x01 => "Pointer",
            0x02 => "Mouse",
            0x04 => "Joystick",
            0x05 => "Game Pad",
            0x06 => "Keyboard",
            0x07 => "Keypad",
            0x08 => "Multi-axis Controller",
            0x30 => "X",
            0x31 => "Y",
            0x32 => "Z",
            0x38 => "Wheel",
            0x80 => "System Control",
            else => null,
        },
        0x02 => "Simulation Control",
        0x05 => "Game Control",
        0x07 => "Keyboard/Keypad",
        0x08 => "LED",
        0x09 => "Button",
        0x0C => switch (usage) { // Consumer
            0x01 => "Consumer Control",
            0x0238 => "AC Pan",
            else => "Consumer",
        },
        0x0D => "Digitizer",
        0x0F => "Physical Input Device",
        0x20 => "Sensor",
        0x8C => "Bar Code Scanner",
        0xF1D0 => switch (usage) { // FIDO
            0x01 => "FIDO U2F Authenticator",
            0x20 => "FIDO Data In",
            0x21 => "FIDO Data Out",
            else => "FIDO",
        },
        // Everything from 0xFF00 up is the vendor's own business.
        0xFF00...0xFFFF => "vendor defined",
        else => null,
    };
}

fn eq(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

fn parseHex(text: ?[]const u8) ?u16 {
    const s = text orelse return null;
    // `0x` is accepted because everyone writes vendor IDs that way half the
    // time.
    const digits = if (std.ascii.startsWithIgnoreCase(s, "0x")) s[2..] else s;
    return std.fmt.parseInt(u16, digits, 16) catch null;
}

fn badArg(io: std.Io, arg: []const u8) !u8 {
    try print(io, "hidinfo: {s} wants a hexadecimal number\n", .{arg});
    return 2;
}

/// Small unbuffered writes to stderr, for the things that happen before the
/// buffered writer exists.
fn write(io: std.Io, text: []const u8) !void {
    var buf: [64]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
    try stderr.interface.writeAll(text);
    try stderr.interface.flush();
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}

test "hexadecimal arguments are parsed the way people write them" {
    try std.testing.expectEqual(@as(?u16, 0x046d), parseHex("046d"));
    try std.testing.expectEqual(@as(?u16, 0x046d), parseHex("0x046D"));
    try std.testing.expectEqual(@as(?u16, 0x1), parseHex("1"));
    try std.testing.expectEqual(@as(?u16, null), parseHex(null));
    try std.testing.expectEqual(@as(?u16, null), parseHex("nonsense"));
    // Wider than a vendor ID.
    try std.testing.expectEqual(@as(?u16, null), parseHex("10000"));
}

test "the usage names cover the pages worth recognising" {
    try std.testing.expectEqualStrings("Mouse", usageName(0x01, 0x02).?);
    try std.testing.expectEqualStrings("Keyboard", usageName(0x01, 0x06).?);
    try std.testing.expectEqualStrings("Button", usageName(0x09, 0x01).?);
    try std.testing.expectEqualStrings("AC Pan", usageName(0x0C, 0x0238).?);
    try std.testing.expectEqualStrings("FIDO U2F Authenticator", usageName(0xF1D0, 0x01).?);
    try std.testing.expectEqualStrings("vendor defined", usageName(0xFF89, 0x10).?);
    try std.testing.expectEqual(@as(?[]const u8, null), usageName(0x01, 0xAAAA));
    try std.testing.expectEqual(@as(?[]const u8, null), usageName(0x1234, 0x01));
}
