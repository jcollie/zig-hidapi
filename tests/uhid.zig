// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A virtual HID device, created through Linux's `uhid` character device.
//!
//! Without this the test suite can only assert things about whatever hardware
//! happens to be plugged into the machine running it, which on a CI runner is
//! nothing at all -- the enumeration test finds an empty list and passes, and
//! every test that needs a device reports `SkipZigTest`. `/dev/uhid` lets a
//! process invent a HID device with a report descriptor of its choosing, which
//! then appears as an ordinary `/dev/hidrawN` node that this library cannot
//! tell from real hardware. That is what makes the assertions below possible:
//! we know exactly what the device should report, because we said so.
//!
//! It needs root, so these tests report `SkipZigTest` on a developer's
//! workstation and do their work in the NixOS virtual machine test, which is
//! where CI runs them.
//!
//! The protocol is `uapi/linux/uhid.h`. Its structures are
//! `__attribute__((packed))` with a `__u64` inside the union, so a faithful
//! Zig `extern` declaration would need `align(1)` on every field of every
//! member and would still be easy to get quietly wrong. The offsets are
//! written out instead: there are fourteen of them, they are checked against
//! the total size at compile time, and an encoding bug shows up as a device
//! that does not appear rather than as a struct that looks right.

const std = @import("std");
const linux = std.os.linux;

/// `enum uhid_event_type`.
pub const EventType = enum(u32) {
    legacy_create = 0,
    destroy = 1,
    start = 2,
    stop = 3,
    open = 4,
    close = 5,
    output = 6,
    legacy_output_ev = 7,
    legacy_input = 8,
    get_report = 9,
    get_report_reply = 10,
    create2 = 11,
    input2 = 12,
    set_report = 13,
    set_report_reply = 14,
    _,
};

/// `enum uhid_report_type`.
pub const ReportType = enum(u8) {
    feature = 0,
    output = 1,
    input = 2,
};

/// `UHID_DATA_MAX`, which is also `HID_MAX_DESCRIPTOR_SIZE`.
pub const data_max = 4096;

/// Offsets into a `struct uhid_event`, which begins with a `__u32` type and
/// continues with the packed union.
const off = struct {
    const kind = 0;
    const body = 4;

    // struct uhid_create2_req
    const create_name = body + 0; // [128]u8
    const create_phys = body + 128; // [64]u8
    const create_uniq = body + 192; // [64]u8
    const create_rd_size = body + 256; // u16
    const create_bus = body + 258; // u16
    const create_vendor = body + 260; // u32
    const create_product = body + 264; // u32
    const create_version = body + 268; // u32
    const create_country = body + 272; // u32
    const create_rd_data = body + 276; // [4096]u8

    // struct uhid_input2_req
    const input_size = body + 0; // u16
    const input_data = body + 2; // [4096]u8

    // struct uhid_output_req
    const output_data = body + 0; // [4096]u8
    const output_size = body + 4096; // u16
    const output_rtype = body + 4098; // u8

    // struct uhid_get_report_req
    const get_id = body + 0; // u32
    const get_rnum = body + 4; // u8
    const get_rtype = body + 5; // u8

    // struct uhid_get_report_reply_req
    const get_reply_id = body + 0; // u32
    const get_reply_err = body + 4; // u16
    const get_reply_size = body + 6; // u16
    const get_reply_data = body + 8; // [4096]u8

    // struct uhid_set_report_req
    const set_id = body + 0; // u32
    const set_rnum = body + 4; // u8
    const set_rtype = body + 5; // u8
    const set_size = body + 6; // u16
    const set_data = body + 8; // [4096]u8

    // struct uhid_set_report_reply_req
    const set_reply_id = body + 0; // u32
    const set_reply_err = body + 4; // u16
};

/// `sizeof(struct uhid_event)`, which is the create request -- the largest
/// member of the union -- plus the type ahead of it.
pub const event_size = off.create_rd_data + data_max;

comptime {
    // The create request is what makes the event this big; if that stops being
    // true the offsets above have drifted from the header.
    std.debug.assert(event_size == 4 + 276 + 4096);
    std.debug.assert(off.get_reply_data + data_max <= event_size);
    std.debug.assert(off.input_data + data_max <= event_size);
}

fn put(buf: []u8, comptime T: type, offset: usize, value: T) void {
    std.mem.writeInt(T, buf[offset..][0..@divExact(@typeInfo(T).int.bits, 8)], value, .little);
}

fn get(buf: []const u8, comptime T: type, offset: usize) T {
    return std.mem.readInt(T, buf[offset..][0..@divExact(@typeInfo(T).int.bits, 8)], .little);
}

/// Copy `text` into a fixed field, NUL padded, truncating rather than
/// overflowing. The kernel treats these as C strings.
fn putStr(buf: []u8, offset: usize, len: usize, text: []const u8) void {
    const keep = @min(text.len, len - 1);
    @memcpy(buf[offset..][0..keep], text[0..keep]);
    @memset(buf[offset + keep ..][0 .. len - keep], 0);
}

/// What a virtual device should look like once the kernel has published it.
pub const Spec = struct {
    name: []const u8,
    phys: []const u8,
    uniq: []const u8,
    /// A `BUS_*` value from `uapi/linux/input.h`.
    bus: u16,
    vendor: u32,
    product: u32,
    version: u32 = 0,
    country: u32 = 0,
    report_descriptor: []const u8,
};

/// An open `/dev/uhid` with a device behind it.
///
/// The fd is non-blocking, because the process that owns it has to keep
/// answering the kernel's requests while it is also the process making them:
/// `Device.getFeatureReport` does not return until something replies to the
/// `UHID_GET_REPORT` the kernel sends here, so the two halves have to make
/// progress at once.
pub const VirtualDevice = struct {
    fd: linux.fd_t,
    /// Answered to every `UHID_GET_REPORT`, after the report ID byte.
    feature_report: []const u8 = &.{},
    /// The most recent report the kernel passed down from a `write` or a
    /// `sendFeatureReport`, and how much of it is valid.
    last_output: [data_max]u8 = undefined,
    last_output_len: usize = 0,
    /// Set once the kernel says a reader has opened the hidraw node.
    opened: bool = false,

    pub const CreateError = error{
        /// `/dev/uhid` is not there, which means the `uhid` module is not
        /// loaded.
        UhidNotAvailable,
        /// `/dev/uhid` is root-only, so this needs privileges the test does
        /// not have.
        UhidNoAccess,
        UhidWriteFailed,
        ReportDescriptorTooLarge,
    };

    pub fn create(spec: Spec) CreateError!VirtualDevice {
        if (spec.report_descriptor.len > data_max) return error.ReportDescriptorTooLarge;

        const rc = linux.open("/dev/uhid", .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
        const fd: linux.fd_t = switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .ACCES, .PERM => return error.UhidNoAccess,
            .NOENT, .NXIO => return error.UhidNotAvailable,
            else => return error.UhidNotAvailable,
        };
        errdefer _ = linux.close(fd);

        // 4 KiB of report descriptor plus the fixed fields; too big for a
        // comfortable stack frame, and only ever one of them at a time.
        const event = std.heap.page_allocator.alloc(u8, event_size) catch
            return error.UhidWriteFailed;
        defer std.heap.page_allocator.free(event);
        @memset(event, 0);

        put(event, u32, off.kind, @intFromEnum(EventType.create2));
        putStr(event, off.create_name, 128, spec.name);
        putStr(event, off.create_phys, 64, spec.phys);
        putStr(event, off.create_uniq, 64, spec.uniq);
        put(event, u16, off.create_rd_size, @intCast(spec.report_descriptor.len));
        put(event, u16, off.create_bus, spec.bus);
        put(event, u32, off.create_vendor, spec.vendor);
        put(event, u32, off.create_product, spec.product);
        put(event, u32, off.create_version, spec.version);
        put(event, u32, off.create_country, spec.country);
        @memcpy(event[off.create_rd_data..][0..spec.report_descriptor.len], spec.report_descriptor);

        try writeAll(fd, event);
        return .{ .fd = fd };
    }

    /// Remove the device and close the descriptor.
    pub fn destroy(self: *VirtualDevice) void {
        var event: [8]u8 = @splat(0);
        put(&event, u32, off.kind, @intFromEnum(EventType.destroy));
        writeAll(self.fd, &event) catch {};
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// Send an input report, as a real device would on its interrupt IN
    /// endpoint.
    pub fn sendInput(self: *VirtualDevice, report: []const u8) !void {
        std.debug.assert(report.len <= data_max);
        const event = try std.heap.page_allocator.alloc(u8, off.input_data + report.len);
        defer std.heap.page_allocator.free(event);
        @memset(event, 0);
        put(event, u32, off.kind, @intFromEnum(EventType.input2));
        put(event, u16, off.input_size, @intCast(report.len));
        @memcpy(event[off.input_data..][0..report.len], report);
        try writeAll(self.fd, event);
    }

    /// Handle whatever the kernel has to say, if anything.
    ///
    /// Returns the event handled, or `null` when there was none waiting. The
    /// caller is expected to keep calling this: a `UHID_GET_REPORT` left
    /// unanswered makes the reader's ioctl fail after the kernel's own five
    /// second timeout, which reads as a mysteriously slow test rather than as
    /// the missing reply it is.
    pub fn poll(self: *VirtualDevice) !?EventType {
        var event: [event_size]u8 = undefined;
        const rc = linux.read(self.fd, &event, event.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return null,
            else => return error.UhidReadFailed,
        }

        const kind: EventType = @enumFromInt(get(&event, u32, off.kind));
        switch (kind) {
            .open => self.opened = true,
            .close => self.opened = false,

            .get_report => {
                const id = get(&event, u32, off.get_id);
                const rnum = event[off.get_rnum];

                var reply: [event_size]u8 = @splat(0);
                put(&reply, u32, off.kind, @intFromEnum(EventType.get_report_reply));
                put(&reply, u32, off.get_reply_id, id);
                put(&reply, u16, off.get_reply_err, 0);
                // The report ID leads, exactly as it does everywhere else in
                // HID, and the caller's buffer already has it in the first
                // byte on the way in.
                const len = self.feature_report.len + 1;
                put(&reply, u16, off.get_reply_size, @intCast(len));
                reply[off.get_reply_data] = rnum;
                @memcpy(reply[off.get_reply_data + 1 ..][0..self.feature_report.len], self.feature_report);
                try writeAll(self.fd, reply[0 .. off.get_reply_data + len]);
            },

            .set_report => {
                const id = get(&event, u32, off.set_id);
                const size = get(&event, u16, off.set_size);
                self.last_output_len = @min(size, data_max);
                @memcpy(
                    self.last_output[0..self.last_output_len],
                    event[off.set_data..][0..self.last_output_len],
                );

                var reply: [16]u8 = @splat(0);
                put(&reply, u32, off.kind, @intFromEnum(EventType.set_report_reply));
                put(&reply, u32, off.set_reply_id, id);
                put(&reply, u16, off.set_reply_err, 0);
                try writeAll(self.fd, reply[0 .. off.set_reply_err + 2]);
            },

            .output => {
                const size = get(&event, u16, off.output_size);
                self.last_output_len = @min(size, data_max);
                @memcpy(
                    self.last_output[0..self.last_output_len],
                    event[off.output_data..][0..self.last_output_len],
                );
            },

            else => {},
        }
        return kind;
    }

    /// The output or feature report the kernel most recently passed down.
    pub fn lastOutput(self: *const VirtualDevice) []const u8 {
        return self.last_output[0..self.last_output_len];
    }
};

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + written, bytes.len - written);
        switch (linux.errno(rc)) {
            .SUCCESS => written += rc,
            .AGAIN, .INTR => continue,
            else => return error.UhidWriteFailed,
        }
    }
}

test "the event offsets match the header's packed layout" {
    // Each of these is a field's offset within `struct uhid_event` as gcc
    // lays it out with `__attribute__((packed))`. Getting one wrong produces
    // a device that either fails to appear or appears with nonsense in it, so
    // they are worth pinning even though nothing but this file reads them.
    try std.testing.expectEqual(@as(usize, 4), off.create_name);
    try std.testing.expectEqual(@as(usize, 132), off.create_phys);
    try std.testing.expectEqual(@as(usize, 196), off.create_uniq);
    try std.testing.expectEqual(@as(usize, 260), off.create_rd_size);
    try std.testing.expectEqual(@as(usize, 262), off.create_bus);
    try std.testing.expectEqual(@as(usize, 264), off.create_vendor);
    try std.testing.expectEqual(@as(usize, 268), off.create_product);
    try std.testing.expectEqual(@as(usize, 280), off.create_rd_data);
    try std.testing.expectEqual(@as(usize, 4376), event_size);
}

test "a string field is NUL padded and truncated rather than overrun" {
    var buf: [16]u8 = @splat(0xAA);
    putStr(&buf, 0, 8, "abc");
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c', 0, 0, 0, 0, 0 }, buf[0..8]);
    // Untouched past the field.
    try std.testing.expectEqual(@as(u8, 0xAA), buf[8]);

    putStr(&buf, 0, 4, "abcdefgh");
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c', 0 }, buf[0..4]);
}
