// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The `IOCTL_HID_*` control codes, and the one structure they exchange that
//! nothing else declares.
//!
//! These are written out by hand because they are not in the Win32 metadata
//! and so not in zigwin32: they live in the WDK's `hidclass.h`, which is a
//! driver header, and the documented user-mode way to reach them is the
//! `HidD_*` functions in `hid.dll`. Those functions are thin wrappers -- Wine's
//! `dlls/hid/hidd.c` shows the mapping is one to one -- and going straight to
//! the control code means every request in this backend is one
//! `io.operate(.device_io_control)`, cancelable and timeout-capable, rather
//! than a blocking call to a DLL that `Io` cannot interrupt.
//!
//! The one thing that cannot be had this way is the three report lengths; see
//! `windows.zig`.
//!
//! `CTL_CODE(DeviceType, Function, Method, Access)` packs its arguments as
//! `(DeviceType << 16) | (Access << 14) | (Function << 2) | Method`, which is
//! exactly the layout of `std.os.windows.CTL_CODE`, so the builders below are
//! struct literals rather than arithmetic. Every value is asserted below
//! against the number the C macro produces.

const std = @import("std");
const windows = std.os.windows;

const CTL_CODE = windows.CTL_CODE;

/// Every HID control code is numbered in the keyboard device's space, which
/// is a historical accident and not a statement about the device.
const device: CTL_CODE.FILE_DEVICE = .KEYBOARD;

/// `HID_CTL_CODE(id)` -- `METHOD_NEITHER`.
fn hid(id: u12) CTL_CODE {
    return .{ .DeviceType = device, .Access = .ANY, .Function = id, .Method = .NEITHER };
}

/// `HID_BUFFER_CTL_CODE(id)` -- `METHOD_BUFFERED`.
fn buffered(id: u12) CTL_CODE {
    return .{ .DeviceType = device, .Access = .ANY, .Function = id, .Method = .BUFFERED };
}

/// `HID_IN_CTL_CODE(id)` -- `METHOD_IN_DIRECT`, i.e. the caller supplies the
/// data.
fn in(id: u12) CTL_CODE {
    return .{ .DeviceType = device, .Access = .ANY, .Function = id, .Method = .IN_DIRECT };
}

/// `HID_OUT_CTL_CODE(id)` -- `METHOD_OUT_DIRECT`, i.e. the driver fills the
/// caller's buffer.
fn out(id: u12) CTL_CODE {
    return .{ .DeviceType = device, .Access = .ANY, .Function = id, .Method = .OUT_DIRECT };
}

pub const GET_NUM_DEVICE_INPUT_BUFFERS = buffered(104);
pub const SET_NUM_DEVICE_INPUT_BUFFERS = buffered(105);
pub const GET_COLLECTION_INFORMATION = buffered(106);

/// Returns the class driver's *preparsed data*, despite the name -- an
/// opaque, undocumented structure it built from the report descriptor, and
/// not the descriptor itself. See `windows.zig` on why this library reports
/// `error.Unsupported` for `getReportDescriptor` rather than reconstructing
/// one.
pub const GET_COLLECTION_DESCRIPTOR = hid(100);
pub const FLUSH_QUEUE = hid(101);

pub const SET_FEATURE = in(100);
pub const SET_OUTPUT_REPORT = in(101);

pub const GET_FEATURE = out(100);
pub const GET_INPUT_REPORT = out(104);
pub const GET_OUTPUT_REPORT = out(105);
pub const GET_MANUFACTURER_STRING = out(110);
pub const GET_PRODUCT_STRING = out(111);
pub const GET_SERIALNUMBER_STRING = out(112);
pub const GET_INDEXED_STRING = out(120);

/// What `IOCTL_HID_GET_COLLECTION_INFORMATION` fills in.
///
/// `HID_COLLECTION_INFORMATION` is a `hidclass.h` type, so it is not in the
/// Win32 metadata either. Declaring a structure is not a call, so writing it
/// out here does not reach around zigwin32 for anything zigwin32 provides.
pub const CollectionInformation = extern struct {
    /// The size of the report descriptor the class driver parsed. Note that
    /// knowing the size is not the same as being able to read it back.
    descriptor_size: u32,
    polled: u8,
    reserved1: [1]u8,
    vendor_id: u16,
    product_id: u16,
    version_number: u16,

    comptime {
        std.debug.assert(@sizeOf(CollectionInformation) == 12);
    }
};

test "the codes match what hidclass.h's macros produce" {
    // `CTL_CODE(FILE_DEVICE_KEYBOARD /* 0x0b */, id, method, FILE_ANY_ACCESS)`
    // worked through by hand. A wrong code is answered with
    // STATUS_INVALID_DEVICE_REQUEST, which says nothing about which code was
    // wrong, so these are worth pinning by value.
    const value = struct {
        fn of(c: CTL_CODE) u32 {
            return @bitCast(c);
        }
    }.of;

    try std.testing.expectEqual(@as(u32, 0x000b_01a0), value(GET_NUM_DEVICE_INPUT_BUFFERS));
    try std.testing.expectEqual(@as(u32, 0x000b_01a4), value(SET_NUM_DEVICE_INPUT_BUFFERS));
    try std.testing.expectEqual(@as(u32, 0x000b_01a8), value(GET_COLLECTION_INFORMATION));
    try std.testing.expectEqual(@as(u32, 0x000b_0193), value(GET_COLLECTION_DESCRIPTOR));
    try std.testing.expectEqual(@as(u32, 0x000b_0197), value(FLUSH_QUEUE));
    try std.testing.expectEqual(@as(u32, 0x000b_0191), value(SET_FEATURE));
    try std.testing.expectEqual(@as(u32, 0x000b_0195), value(SET_OUTPUT_REPORT));
    try std.testing.expectEqual(@as(u32, 0x000b_0192), value(GET_FEATURE));
    try std.testing.expectEqual(@as(u32, 0x000b_01a2), value(GET_INPUT_REPORT));
    try std.testing.expectEqual(@as(u32, 0x000b_01a6), value(GET_OUTPUT_REPORT));
    try std.testing.expectEqual(@as(u32, 0x000b_01ba), value(GET_MANUFACTURER_STRING));
    try std.testing.expectEqual(@as(u32, 0x000b_01be), value(GET_PRODUCT_STRING));
    try std.testing.expectEqual(@as(u32, 0x000b_01c2), value(GET_SERIALNUMBER_STRING));
    try std.testing.expectEqual(@as(u32, 0x000b_01e2), value(GET_INDEXED_STRING));
}

test "std's CTL_CODE packs its fields the way the C macro does" {
    // The whole reason the builders above are struct literals rather than
    // shifts. If `std.os.windows.CTL_CODE`'s field order ever changed, every
    // code in this file would silently become a different request.
    const c: CTL_CODE = .{
        .DeviceType = .KEYBOARD,
        .Access = .ANY,
        .Function = 100,
        .Method = .OUT_DIRECT,
    };
    const expected: u32 = (0x0b << 16) | (0 << 14) | (100 << 2) | 2;
    try std.testing.expectEqual(expected, @as(u32, @bitCast(c)));
}

test {
    std.testing.refAllDecls(@This());
}
