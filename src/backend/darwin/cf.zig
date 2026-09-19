// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! CoreFoundation, declared rather than imported.
//!
//! Zig 0.16 has no CoreFoundation bindings and `@cImport` would need the macOS
//! SDK, which would stop this library from being compiled for macOS anywhere
//! but on a Mac. Writing the declarations out keeps `zig build check` able to
//! compile this backend from a Linux machine, which is the only coverage it
//! gets until it runs on a real one.
//!
//! The opaque pointer types are `?*anyopaque` because the structures behind
//! them are private; nothing here dereferences one.
//!
//! **Mind which of these are data symbols.** `kCFAllocatorDefault`,
//! `kCFRunLoopDefaultMode` and `kCFCoreFoundationVersionNumber` are variables
//! exported by the framework and have to be `extern const`. Almost everything
//! else that looks like a constant in Apple's headers -- every `kIOHID*Key`,
//! for instance -- is a C preprocessor `#define` of a string literal and is
//! not a symbol at all, so declaring one `extern` produces a link error on the
//! one platform that is hardest to test. See `iokit.zig`, where they are
//! ordinary Zig string constants.

const std = @import("std");

pub const CFTypeRef = ?*const anyopaque;
pub const CFStringRef = ?*const anyopaque;
pub const CFNumberRef = ?*const anyopaque;
pub const CFDataRef = ?*const anyopaque;
pub const CFSetRef = ?*const anyopaque;
pub const CFDictionaryRef = ?*const anyopaque;
pub const CFAllocatorRef = ?*const anyopaque;
pub const CFRunLoopRef = ?*anyopaque;
pub const CFRunLoopSourceRef = ?*anyopaque;

/// `CFIndex` is `signed long`, which is 64 bits on every Darwin target this
/// library supports.
pub const CFIndex = c_long;
pub const CFTypeID = c_ulong;
pub const CFTimeInterval = f64;

/// `Boolean` is `unsigned char`, not a Zig `bool`.
pub const Boolean = u8;
pub const CFStringEncoding = u32;
pub const CFNumberType = CFIndex;

pub const kCFStringEncodingUTF8: CFStringEncoding = 0x0800_0100;

pub const kCFNumberSInt32Type: CFNumberType = 3;
pub const kCFNumberSInt64Type: CFNumberType = 4;

pub const CFRunLoopRunResult = enum(i32) {
    finished = 1,
    stopped = 2,
    timed_out = 3,
    handled_source = 4,
    _,
};

// ---- exported data symbols ------------------------------------------------

pub extern const kCFAllocatorDefault: CFAllocatorRef;
pub extern const kCFRunLoopDefaultMode: CFStringRef;

/// The framework's version, which is the supported way to ask how old the
/// system is. `close` in `darwin.zig` branches on it, because whether
/// `IOHIDDeviceClose` may be called on a device that has been unplugged
/// changed with 10.10 and changed back with 10.15.
pub extern const kCFCoreFoundationVersionNumber: f64;

/// macOS 10.10.
pub const version_10_10: f64 = 1151.16;

// ---- functions ------------------------------------------------------------

pub extern fn CFRelease(cf: CFTypeRef) callconv(.c) void;
pub extern fn CFGetTypeID(cf: CFTypeRef) callconv(.c) CFTypeID;

pub extern fn CFStringGetTypeID() callconv(.c) CFTypeID;
pub extern fn CFNumberGetTypeID() callconv(.c) CFTypeID;
pub extern fn CFDataGetTypeID() callconv(.c) CFTypeID;

pub extern fn CFStringCreateWithCString(
    alloc: CFAllocatorRef,
    cStr: [*:0]const u8,
    encoding: CFStringEncoding,
) callconv(.c) CFStringRef;

pub extern fn CFStringGetCString(
    theString: CFStringRef,
    buffer: [*]u8,
    bufferSize: CFIndex,
    encoding: CFStringEncoding,
) callconv(.c) Boolean;

pub extern fn CFNumberGetValue(
    number: CFNumberRef,
    theType: CFNumberType,
    valuePtr: *anyopaque,
) callconv(.c) Boolean;

pub extern fn CFDataGetBytePtr(theData: CFDataRef) callconv(.c) ?[*]const u8;
pub extern fn CFDataGetLength(theData: CFDataRef) callconv(.c) CFIndex;

pub extern fn CFSetGetCount(theSet: CFSetRef) callconv(.c) CFIndex;
pub extern fn CFSetGetValues(theSet: CFSetRef, values: [*]?*const anyopaque) callconv(.c) void;

pub extern fn CFRunLoopGetCurrent() callconv(.c) CFRunLoopRef;
pub extern fn CFRunLoopGetMain() callconv(.c) CFRunLoopRef;
pub extern fn CFRunLoopRunInMode(
    mode: CFStringRef,
    seconds: CFTimeInterval,
    returnAfterSourceHandled: Boolean,
) callconv(.c) CFRunLoopRunResult;
pub extern fn CFRunLoopStop(rl: CFRunLoopRef) callconv(.c) void;
pub extern fn CFRunLoopWakeUp(rl: CFRunLoopRef) callconv(.c) void;

pub const CFRunLoopSourceContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: ?*const fn (?*const anyopaque) callconv(.c) ?*const anyopaque = null,
    release: ?*const fn (?*const anyopaque) callconv(.c) void = null,
    copyDescription: ?*const fn (?*const anyopaque) callconv(.c) CFStringRef = null,
    equal: ?*const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) Boolean = null,
    hash: ?*const fn (?*const anyopaque) callconv(.c) CFIndex = null,
    schedule: ?*const fn (?*anyopaque, CFRunLoopRef, CFStringRef) callconv(.c) void = null,
    cancel: ?*const fn (?*anyopaque, CFRunLoopRef, CFStringRef) callconv(.c) void = null,
    perform: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

pub extern fn CFRunLoopSourceCreate(
    allocator: CFAllocatorRef,
    order: CFIndex,
    context: *CFRunLoopSourceContext,
) callconv(.c) CFRunLoopSourceRef;
pub extern fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) callconv(.c) void;
pub extern fn CFRunLoopSourceSignal(source: CFRunLoopSourceRef) callconv(.c) void;
pub extern fn CFRunLoopSourceInvalidate(source: CFRunLoopSourceRef) callconv(.c) void;

// ---- small helpers --------------------------------------------------------

/// Copy a `CFString` into `buf` as UTF-8, or `null` if it is not a string or
/// does not fit.
///
/// Every property read goes through a type check like this one. It is not
/// paranoia: `IOHIDDeviceGetProperty` returns whatever the device's driver
/// published, and a driver is free to publish a number where the key says
/// string.
pub fn stringValue(value: CFTypeRef, buf: []u8) ?[]const u8 {
    if (value == null) return null;
    if (CFGetTypeID(value) != CFStringGetTypeID()) return null;
    if (CFStringGetCString(value, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8) == 0) return null;
    return std.mem.sliceTo(buf, 0);
}

/// Read a `CFNumber` as a 32 bit integer, or `null` if it is not a number.
pub fn intValue(value: CFTypeRef) ?i32 {
    if (value == null) return null;
    if (CFGetTypeID(value) != CFNumberGetTypeID()) return null;
    var out: i32 = 0;
    if (CFNumberGetValue(value, kCFNumberSInt32Type, &out) == 0) return null;
    return out;
}

/// The bytes of a `CFData`, or `null` if it is not one.
pub fn dataValue(value: CFTypeRef) ?[]const u8 {
    if (value == null) return null;
    if (CFGetTypeID(value) != CFDataGetTypeID()) return null;
    const ptr = CFDataGetBytePtr(value) orelse return null;
    const len = CFDataGetLength(value);
    if (len <= 0) return null;
    return ptr[0..@intCast(len)];
}

test {
    std.testing.refAllDecls(@This());
}
