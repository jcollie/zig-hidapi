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
};

/// The backend for this target.
pub const impl = switch (builtin.os.tag) {
    .linux => @import("backend/linux.zig"),
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
}
