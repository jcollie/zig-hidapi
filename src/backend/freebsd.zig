// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The FreeBSD backend: `/dev/hidraw*` driven by `hidraw(4)`.
//!
//! FreeBSD's `hidraw(4)` implements Linux's request set on purpose, with the
//! same structures behind it, so everything about an open device is shared
//! with the Linux backend and lives in `hidraw.zig`. What this file carries is
//! the two things that are genuinely different.
//!
//! **The request numbers.** BSD and Linux encode a request differently, and
//! FreeBSD numbers its from group `'U'` where Linux uses `'H'`. `HIDIOCGRDESC`
//! is also a different *shape*: `_IO('U', 31)`, with no size and no direction,
//! where Linux has `_IOR('H', 0x02, struct hidraw_report_descriptor)`. From
//! user space the call is the same -- hand it a pointer to the structure --
//! because for a sizeless request FreeBSD passes the argument slot itself and
//! the driver reads the pointer out of it.
//!
//! **Enumeration.** There is no sysfs, so unlike Linux this has to open every
//! node to ask it anything, and an unprivileged process with no devd rule
//! therefore sees nothing. That is a real difference in behaviour between the
//! two systems and is documented as such rather than papered over.
//!
//! Zig 0.16 ships no raw-syscall layer for FreeBSD, so everything goes through
//! `std.c` and this backend links libc, where the Linux one does not. Nothing
//! in this file calls libc directly; `std.Io` does it.
//!
//! Getting a device node at all takes some arranging on FreeBSD: `usbhid` has
//! to be active, which is the default from 14.2 and wants
//! `hw.usb.usbhid.enable=1` in `/boot/loader.conf` plus `usbhid` in
//! `kld_list` before that. The README says so.

const std = @import("std");

const bsd = @import("bsd_ioctl.zig");
const hidraw = @import("hidraw.zig");

const descriptor = @import("../descriptor.zig");
const errors = @import("../errors.zig");
const DeviceId = @import("../DeviceId.zig");
const DeviceInfo = @import("../DeviceInfo.zig");
const Options = @import("../Enumerator.zig").Options;
const Str = @import("../Str.zig");

const log = std.log.scoped(.hidapi_freebsd);

/// The largest report descriptor the kernel will hand out.
pub const max_report_descriptor_len = hidraw.max_report_descriptor_len;

/// Zero; see `hidraw.recommended_descriptor_scratch`.
pub const recommended_descriptor_scratch = hidraw.recommended_descriptor_scratch;

/// The group every `hidraw(4)` request is numbered in. Linux uses `'H'`.
const group = 'U';

fn GRAWNAME(len: u16) u32 {
    return bsd.IOC(bsd.IOC_OUT, group, 33, @min(len, bsd.max_len));
}
fn GRAWPHYS(len: u16) u32 {
    return bsd.IOC(bsd.IOC_OUT, group, 34, @min(len, bsd.max_len));
}
fn SFEATURE(len: u16) u32 {
    return bsd.IOC(bsd.IOC_IN, group, 35, @min(len, bsd.max_len));
}
fn GFEATURE(len: u16) u32 {
    return bsd.IOC(bsd.IOC_INOUT, group, 36, @min(len, bsd.max_len));
}
fn GRAWUNIQ(len: u16) u32 {
    return bsd.IOC(bsd.IOC_OUT, group, 37, @min(len, bsd.max_len));
}
fn GINPUT(len: u16) u32 {
    return bsd.IOC(bsd.IOC_INOUT, group, 39, @min(len, bsd.max_len));
}

/// FreeBSD's request numbers, from `sys/dev/hid/hidraw.h`.
///
/// Note that `HIDIOCGRAWUNIQ` is here. The `hidraw(4)` manual page does not
/// list it and the header defines it, so a device's serial number is
/// reachable on FreeBSD after all.
pub const requests: hidraw.Requests = .{
    .GRDESCSIZE = bsd.IOR(group, 30, i32),
    .GRDESC = bsd.IO(group, 31),
    .GRAWINFO = bsd.IOR(group, 32, hidraw.DevInfo),
    .GRAWNAME = GRAWNAME,
    .GRAWPHYS = GRAWPHYS,
    .GRAWUNIQ = GRAWUNIQ,
    .SFEATURE = SFEATURE,
    .GFEATURE = GFEATURE,
    .GINPUT = GINPUT,
    .max_len = bsd.max_len,
};

/// An open `/dev/hidraw*` device. Shared with Linux; see `hidraw.zig`.
pub const Device = hidraw.Device(requests, .hidapi_freebsd);

/// Where the device nodes live.
const dev_path = "/dev";

/// The prefix of a `hidraw(4)` node.
///
/// Deliberately not `uhid`. The same device is also published under that name
/// by `make_dev_alias`, for programs written against the older interface, and
/// matching both would report every device twice.
const node_prefix = "hidraw";

/// Walks `/dev` for `hidraw` nodes.
///
/// Unlike the Linux enumerator this has to open each one, because FreeBSD has
/// no sysfs and the only way to ask a device anything is to ask the device.
/// Two consequences worth knowing: enumerating needs the same permissions as
/// opening, so an unprivileged process with no devd rule sees nothing rather
/// than seeing devices it cannot open; and a device another program holds
/// exclusively may not appear.
pub const Enumerator = struct {
    dir: std.Io.Dir,
    it: std.Io.Dir.Iterator,
    options: Options,
    descriptor_buf: []u8,
    exhausted: bool,

    /// One report descriptor is all this backend needs to borrow, since
    /// everything else arrives in fixed structures.
    pub const min_scratch = max_report_descriptor_len;

    pub const recommended_scratch = 8 * 1024;

    pub fn init(
        self: *Enumerator,
        io: std.Io,
        scratch: []u8,
        options: Options,
    ) errors.EnumerateError!void {
        if (scratch.len < min_scratch) return error.BufferTooSmall;

        const dir = std.Io.Dir.openDirAbsolute(io, dev_path, .{ .iterate = true }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                self.* = .{
                    .dir = .{ .handle = -1 },
                    .it = undefined,
                    .options = options,
                    .descriptor_buf = &.{},
                    .exhausted = true,
                };
                return;
            },
        };

        self.* = .{
            .dir = dir,
            .it = dir.iterate(),
            .options = options,
            .descriptor_buf = scratch[0..max_report_descriptor_len],
            .exhausted = false,
        };
    }

    pub fn deinit(self: *Enumerator, io: std.Io) void {
        if (self.dir.handle != -1) self.dir.close(io);
        self.* = undefined;
    }

    pub fn next(
        self: *Enumerator,
        io: std.Io,
        out: *DeviceInfo,
    ) errors.EnumerateError!bool {
        if (self.exhausted) return false;
        while (true) {
            const entry = self.it.next(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return false,
            } orelse return false;

            if (!isNode(entry.name)) continue;
            if (try self.fill(io, entry.name, out)) return true;
        }
    }

    /// `hidraw` followed by at least one digit and nothing else, so that
    /// `hidraw` itself, or some future `hidrawctl`, is not mistaken for a
    /// device.
    fn isNode(name: []const u8) bool {
        if (!std.mem.startsWith(u8, name, node_prefix)) return false;
        const rest = name[node_prefix.len..];
        if (rest.len == 0) return false;
        for (rest) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }

    fn fill(
        self: *Enumerator,
        io: std.Io,
        node: []const u8,
        out: *DeviceInfo,
    ) errors.EnumerateError!bool {
        var path_buf: [DeviceId.max_len]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, dev_path ++ "/{s}", .{node}) catch return false;
        const id = DeviceId.init(path) catch return false;

        var device: Device = undefined;
        // A node we may not open, or that went away between the listing and
        // now, is one we cannot report. Skipping is the only option: unlike
        // Linux there is no second source to ask.
        device.open(io, id, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        defer device.close(io);

        device.getInfo(io, out) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        out.id = id;

        if (!out.matches(self.options.vendor_id, self.options.product_id)) return false;

        if (!self.options.strings) {
            out.manufacturer = .empty;
            out.product = .empty;
            out.serial_number = .empty;
            out.physical_location = .empty;
        }

        if (self.options.usages) {
            const len = device.getReportDescriptorLen(io) catch 0;
            if (len > 0 and len <= self.descriptor_buf.len) {
                if (device.getReportDescriptor(io, self.descriptor_buf[0..len])) |bytes| {
                    if (descriptor.firstUsage(bytes)) |u| {
                        out.usage_page = u.page;
                        out.usage = u.id;
                    }
                } else |_| {}
            }
        }

        return true;
    }
};

test "the request numbers match sys/dev/hid/hidraw.h" {
    // Pinned by value, because a wrong number is answered with ENOTTY and
    // nothing in that answer points at the cause.
    try std.testing.expectEqual(@as(u32, 0x4004_551e), requests.GRDESCSIZE);
    try std.testing.expectEqual(@as(u32, 0x2000_551f), requests.GRDESC);
    try std.testing.expectEqual(@as(u32, 0x4008_5520), requests.GRAWINFO);
    try std.testing.expectEqual(@as(u32, 0x4100_5521), requests.GRAWNAME(256));
    try std.testing.expectEqual(@as(u32, 0x4100_5522), requests.GRAWPHYS(256));
    try std.testing.expectEqual(@as(u32, 0x8040_5523), requests.SFEATURE(64));
    try std.testing.expectEqual(@as(u32, 0xc040_5524), requests.GFEATURE(64));
    try std.testing.expectEqual(@as(u32, 0x4040_5525), requests.GRAWUNIQ(64));
    try std.testing.expectEqual(@as(u32, 0xc040_5527), requests.GINPUT(64));
}

test "the numbers differ from Linux's, which is the entire reason for this file" {
    const linux_requests = @import("linux.zig").requests;
    try std.testing.expect(requests.GRDESCSIZE != linux_requests.GRDESCSIZE);
    try std.testing.expect(requests.GRAWINFO != linux_requests.GRAWINFO);
    try std.testing.expect(requests.GRAWNAME(256) != linux_requests.GRAWNAME(256));
}

test "a node name is hidraw followed by digits and nothing else" {
    try std.testing.expect(Enumerator.isNode("hidraw0"));
    try std.testing.expect(Enumerator.isNode("hidraw42"));
    try std.testing.expect(!Enumerator.isNode("hidraw"));
    try std.testing.expect(!Enumerator.isNode("hidrawctl"));
    // The alias of the same device under the older interface's name. Matching
    // it as well would report every device twice.
    try std.testing.expect(!Enumerator.isNode("uhid0"));
    try std.testing.expect(!Enumerator.isNode("null"));
}

test {
    std.testing.refAllDecls(@This());
}
