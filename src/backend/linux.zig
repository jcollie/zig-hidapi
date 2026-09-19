// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Linux backend: `/dev/hidraw*` driven by the `HIDIOC*` ioctls of
//! `uapi/linux/hidraw.h`, and `/sys/class/hidraw/*` read directly for
//! everything that can be learned without opening a device.
//!
//! Every syscall here goes through `std.os.linux` rather than through libc, so
//! a Linux build of this library links no C at all. That is not true of the
//! other backends -- Zig 0.16 ships no raw-syscall layer for FreeBSD or Darwin
//! and Windows has none to ship -- which is why the choice belongs to the
//! backend and not to the library.
//!
//! The declarations this file has to carry are listed in `contract.zig`.
//! Nothing outside `src/backend/` imports it directly.

const std = @import("std");

const hidraw = @import("hidraw.zig");

const ioctl = @import("linux/ioctl.zig");
const sysfs = @import("linux/sysfs.zig");

const descriptor = @import("../descriptor.zig");
const errors = @import("../errors.zig");
const DeviceId = @import("../DeviceId.zig");
const DeviceInfo = @import("../DeviceInfo.zig");
const Options = @import("../Enumerator.zig").Options;
const Str = @import("../Str.zig");

/// The largest report descriptor the kernel will hand out, so a buffer this
/// size always fits one.
pub const max_report_descriptor_len = hidraw.max_report_descriptor_len;

/// Linux's request numbers, from `uapi/linux/hidraw.h`.
///
/// The fixed ones come out of `std.os.linux.IOCTL`; the ones carrying a
/// caller's buffer are built by hand, because the length is part of the
/// number.
pub const requests: hidraw.Requests = .{
    .GRDESCSIZE = ioctl.HIDIOCGRDESCSIZE,
    .GRDESC = ioctl.HIDIOCGRDESC,
    .GRAWINFO = ioctl.HIDIOCGRAWINFO,
    .GRAWNAME = ioctl.HIDIOCGRAWNAME,
    .GRAWPHYS = ioctl.HIDIOCGRAWPHYS,
    .GRAWUNIQ = ioctl.HIDIOCGRAWUNIQ,
    .SFEATURE = ioctl.HIDIOCSFEATURE,
    .GFEATURE = ioctl.HIDIOCGFEATURE,
    .GINPUT = ioctl.HIDIOCGINPUT,
    .max_len = ioctl.max_len,
};

/// An open `/dev/hidraw*` device.
///
/// Every line of it is shared with FreeBSD, which implements the same request
/// set with different numbers; see `hidraw.zig`.
pub const Device = hidraw.Device(requests, .hidapi_linux);

/// Walks `/sys/class/hidraw`.
///
/// Nothing here opens a device, which is the point: the class directory is
/// world readable where the nodes are not, so an unprivileged process with no
/// udev rule can still see what is attached. It also means enumeration costs
/// no permission and cannot disturb a device another process is using.
pub const Enumerator = struct {
    dir: std.Io.Dir,
    it: std.Io.Dir.Iterator,
    options: Options,
    bufs: Bufs,
    /// Set when there is nothing to iterate, so that `next` answers without
    /// touching an iterator that was never initialised.
    exhausted: bool,

    /// Scratch this backend will not work below: one report descriptor, one
    /// `uevent`, and room for the attribute strings.
    pub const min_scratch = max_report_descriptor_len + uevent_len + Str.max_len;

    /// Comfortable scratch, and what `Enumerator.recommended_scratch` is.
    pub const recommended_scratch = 16 * 1024;

    /// `uevent` is a handful of short lines; sysfs reports every attribute as
    /// one page regardless, and reads short.
    const uevent_len = 4096;

    const Bufs = struct {
        uevent: []u8,
        report_descriptor: []u8,
        attribute: []u8,
    };

    pub fn init(
        self: *Enumerator,
        io: std.Io,
        scratch: []u8,
        options: Options,
    ) errors.EnumerateError!void {
        if (scratch.len < min_scratch) return error.BufferTooSmall;

        const dir = std.Io.Dir.openDirAbsolute(io, sysfs.class_path, .{ .iterate = true }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // No class directory means no hidraw driver, which is an empty
            // list rather than a failure -- the same answer a machine with no
            // HID devices gives.
            else => {
                self.* = .{
                    .dir = .{ .handle = -1 },
                    .it = undefined,
                    .options = options,
                    .bufs = undefined,
                    .exhausted = true,
                };
                return;
            },
        };

        var rest = scratch;
        const uevent = rest[0..uevent_len];
        rest = rest[uevent_len..];
        const rd = rest[0..max_report_descriptor_len];
        rest = rest[max_report_descriptor_len..];
        const attribute = rest[0..Str.max_len];

        self.* = .{
            .dir = dir,
            .it = dir.iterate(),
            .options = options,
            .bufs = .{ .uevent = uevent, .report_descriptor = rd, .attribute = attribute },
            .exhausted = false,
        };
    }

    pub fn deinit(self: *Enumerator, io: std.Io) void {
        if (!self.exhausted or self.dir.handle != -1) self.dir.close(io);
        self.* = undefined;
    }

    /// Fill `out` with the next device, or answer `false` when there are none
    /// left.
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

            if (try self.fill(io, entry.name, out)) return true;
        }
    }

    /// Everything read for one `hidrawN` entry. `false` means skip it: either
    /// it does not look like a HID device, or the caller filtered it out.
    fn fill(
        self: *Enumerator,
        io: std.Io,
        node: []const u8,
        out: *DeviceInfo,
    ) errors.EnumerateError!bool {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

        const uevent_path = std.fmt.bufPrint(&path_buf, "{s}/device/uevent", .{node}) catch
            return false;
        const text = try sysfs.readAttribute(io, self.dir, uevent_path, self.bufs.uevent) orelse
            return false;
        const attrs = sysfs.parseUevent(text);

        out.* = .empty;
        out.vendor_id = attrs.vendor;
        out.product_id = attrs.product;
        out.native_bus = attrs.bus;
        out.bus_type = hidraw.busType(attrs.bus);

        if (!out.matches(self.options.vendor_id, self.options.product_id)) return false;

        out.id = DeviceId.init(
            std.fmt.bufPrint(&path_buf, "/dev/{s}", .{node}) catch return false,
        ) catch return false;

        if (self.options.strings) {
            out.product = .init(attrs.name);
            out.serial_number = .init(attrs.uniq);
            out.physical_location = .init(attrs.phys);

            // Only USB has the ancestors these live on. On anything else
            // `device/../..` belongs to a different subsystem entirely, so the
            // files are absent and reading them would be meaningless even if
            // they were not.
            if (sysfs.isUsb(attrs)) {
                if (try sysfs.usbAttribute(io, self.dir, node, "manufacturer", self.bufs.attribute)) |m|
                    out.manufacturer = .init(m);
                // The USB device's own product string is the better answer
                // when there is one: `HID_NAME` is it with the manufacturer
                // glued to the front.
                if (try sysfs.usbAttribute(io, self.dir, node, "product", self.bufs.attribute)) |p|
                    out.product = .init(p);
                if (try sysfs.usbAttribute(io, self.dir, node, "serial", self.bufs.attribute)) |s|
                    out.serial_number = .init(s);
                if (try sysfs.usbAttribute(io, self.dir, node, "bcdDevice", self.bufs.attribute)) |b|
                    out.release_number = std.fmt.parseInt(u16, b, 16) catch 0;
                out.interface_number = try sysfs.usbInterfaceNumber(io, self.dir, node);
            }
        }

        if (self.options.usages) {
            const rd_path = std.fmt.bufPrint(&path_buf, "{s}/device/report_descriptor", .{node}) catch
                return true;
            if (try sysfs.readAttribute(io, self.dir, rd_path, self.bufs.report_descriptor)) |bytes| {
                if (descriptor.firstUsage(bytes)) |u| {
                    out.usage_page = u.page;
                    out.usage = u.id;
                }
            }
        }

        return true;
    }
};

test {
    std.testing.refAllDecls(@This());
}
