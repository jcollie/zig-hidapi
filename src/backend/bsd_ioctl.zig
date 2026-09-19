// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Building BSD ioctl request numbers.
//!
//! BSD and Linux encode a request differently, which is the one real
//! difference between talking to Linux's `hidraw` and FreeBSD's: the
//! structures are the same, the names are the same, and the numbers are not.
//! BSD packs a 13 bit length into bits 16..28, the group character into bits
//! 8..15 and the request number into bits 0..7, and spends the top three bits
//! on the direction. Linux gives the length 14 bits on most architectures and
//! uses two bits for the direction with different values.
//!
//! `std.c` has no general `_IOC` for this -- only a private `ior` inside the
//! Darwin `T` struct, which does not cover `_IOW` or `_IOWR` and is not
//! exported -- so it is written out here, from `sys/sys/ioccom.h`.

const std = @import("std");

/// `IOCPARM_MASK`: the length field is 13 bits, so this is the largest buffer
/// a BSD request number can name. Linux manages 14 bits on most
/// architectures, which is why the bound travels with the request table
/// rather than being a constant of the library.
pub const param_mask: u32 = 0x1fff;

/// The largest `len` any of the builders below accepts.
pub const max_len: u16 = param_mask;

/// No data is transferred: the argument *is* the value.
pub const IOC_VOID: u32 = 0x2000_0000;
/// Copied out of the kernel, i.e. the caller is reading.
pub const IOC_OUT: u32 = 0x4000_0000;
/// Copied into the kernel, i.e. the caller is writing.
pub const IOC_IN: u32 = 0x8000_0000;
/// Both, which is what a request that hands a buffer down and gets it back
/// filled in uses.
pub const IOC_INOUT: u32 = IOC_IN | IOC_OUT;

/// `_IOC(inout, group, num, len)`.
///
/// A `len` wider than `param_mask` would silently wrap into the group field
/// and name a different request entirely, so it is clamped by the callers
/// through `max_len` rather than being allowed to happen here.
pub fn IOC(inout: u32, group: u8, num: u8, len: u16) u32 {
    std.debug.assert(len <= max_len);
    return inout |
        ((@as(u32, len) & param_mask) << 16) |
        (@as(u32, group) << 8) |
        @as(u32, num);
}

/// `_IO(group, num)` -- no argument, or an argument passed by value.
pub fn IO(group: u8, num: u8) u32 {
    return IOC(IOC_VOID, group, num, 0);
}

/// `_IOR(group, num, T)` -- the kernel fills in a `T`.
pub fn IOR(group: u8, num: u8, comptime T: type) u32 {
    return IOC(IOC_OUT, group, num, @sizeOf(T));
}

/// `_IOW(group, num, T)` -- the caller supplies a `T`.
pub fn IOW(group: u8, num: u8, comptime T: type) u32 {
    return IOC(IOC_IN, group, num, @sizeOf(T));
}

/// `_IOWR(group, num, T)` -- the caller supplies a `T` and gets it back.
pub fn IOWR(group: u8, num: u8, comptime T: type) u32 {
    return IOC(IOC_INOUT, group, num, @sizeOf(T));
}

test "the numbers match what the C macros produce" {
    // Checked against `sys/dev/hid/hidraw.h` as of FreeBSD main. Getting one
    // of these wrong names a different request, which the kernel answers with
    // ENOTTY rather than with anything that points at the cause, so they are
    // worth pinning by value.
    //
    // HIDIOCGRDESCSIZE = _IOR('U', 30, int)
    try std.testing.expectEqual(@as(u32, 0x4004_551e), IOR('U', 30, i32));
    // HIDIOCGRDESC = _IO('U', 31) -- no size and no direction, which is the
    // one place FreeBSD's table is a different *shape* from Linux's and not
    // merely different numbers.
    try std.testing.expectEqual(@as(u32, 0x2000_551f), IO('U', 31));
    // HIDIOCGRAWNAME(len) = _IOC(IOC_OUT, 'U', 33, len)
    try std.testing.expectEqual(@as(u32, 0x4100_5521), IOC(IOC_OUT, 'U', 33, 256));
    // HIDIOCSFEATURE(len) = _IOC(IOC_IN, 'U', 35, len)
    try std.testing.expectEqual(@as(u32, 0x8040_5523), IOC(IOC_IN, 'U', 35, 64));
    // HIDIOCGFEATURE(len) = _IOC(IOC_INOUT, 'U', 36, len)
    try std.testing.expectEqual(@as(u32, 0xc040_5524), IOC(IOC_INOUT, 'U', 36, 64));
}

test "the length field is 13 bits and does not run into the group" {
    // 0x1fff is the widest length that fits. One more would carry into bit 29,
    // which is part of the direction, and change what the request means.
    const widest = IOC(IOC_OUT, 'U', 33, max_len);
    try std.testing.expectEqual(@as(u32, 0x1fff), (widest >> 16) & param_mask);
    try std.testing.expectEqual(@as(u32, 'U'), (widest >> 8) & 0xff);
    try std.testing.expectEqual(@as(u32, 33), widest & 0xff);
    try std.testing.expectEqual(IOC_OUT, widest & 0xe000_0000);
}

test {
    std.testing.refAllDecls(@This());
}
