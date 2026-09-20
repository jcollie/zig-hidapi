// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Picks the backend for the operating system being built for.
//!
//! This is the only file in the library that names an operating system.
//! Everything above it goes through `Device`, which forwards to `impl`, and
//! everything below it lives in one file per system under `src/backend/`.
//! `contract.zig` says what such a file has to provide.

const std = @import("std");
const builtin = @import("builtin");

const contract = @import("backend/contract.zig");

/// The systems there is a backend for, which is what the error below names.
/// Keeping the list beside the switch is what stops the message going stale
/// as backends are added.
pub const supported = [_]std.Target.Os.Tag{
    .linux,
    .freebsd,
    .windows,
    .macos,
};

/// The backend for this target.
pub const impl = switch (builtin.os.tag) {
    .linux => @import("backend/linux.zig"),
    .freebsd => @import("backend/freebsd.zig"),
    .windows => @import("backend/windows.zig"),
    .macos, .ios, .tvos, .watchos, .visionos => @import("backend/darwin.zig"),
    else => @compileError(unsupported),
};

const unsupported = blk: {
    var msg: []const u8 = "zig-hidapi has no HID backend for " ++
        @tagName(builtin.os.tag) ++ ". Supported targets are:";
    for (supported) |tag| msg = msg ++ " " ++ @tagName(tag);
    break :blk msg ++ ".";
};

comptime {
    // Referencing `impl` here is load-bearing. A `switch` at container scope
    // is analyzed lazily, so without this the first thing a user on an
    // unsupported target sees is whichever declaration inside `Device` happens
    // to be analyzed first -- "root struct of file 'backend' has no member
    // named 'open'" -- rather than the message above.
    _ = impl;
    contract.check(impl);
}

test {
    std.testing.refAllDecls(@This());

    // Also compile the backends for *other* systems, where they compile on
    // this host at all, so that their tests run here.
    //
    // What that buys is the request number tables. Those are pure arithmetic
    // checked against the kernel headers, and getting one wrong is answered
    // with `ENOTTY` -- an error that says nothing whatever about the cause --
    // so they are worth checking on whatever machine runs the suite rather
    // than only on the system they are for. Nobody has a FreeBSD box to hand
    // every time they touch this.
    //
    // Only the ones that can. `backend/linux.zig` names `std.os.linux.IOCTL`
    // and so compiles on Linux alone; the FreeBSD backend touches nothing
    // platform-specific, because everything it does goes through `std.Io`.
    if (builtin.os.tag == .linux) _ = @import("backend/freebsd.zig");

    // The Windows backend's own file cannot be compiled here -- it imports
    // the `zigwin32` package, which is a lazy dependency a Linux build has no
    // reason to fetch -- but the two parts of it that are pure logic can.
    // Those are the parts worth checking anyway: the control codes, which are
    // answered with STATUS_INVALID_DEVICE_REQUEST when wrong, and the path
    // parsing, which is what decides whether a device is skipped.
    _ = @import("backend/windows/ioctl.zig");
    _ = @import("backend/windows/path.zig");
    _ = @import("backend/windows/item.zig");
    _ = @import("backend/windows/preparsed.zig");
    _ = @import("backend/windows/reconstruct.zig");
    _ = @import("backend/darwin/naming.zig");
    _ = @import("backend/darwin/ReportQueue.zig");
}
