// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The root of `zig build check`, whose only job is to make the compiler look
//! at everything.
//!
//! Compiling `src/hidapi.zig` straight to an object does far less than it
//! appears to. Zig analyzes declarations lazily and a library exports no
//! symbols, so nothing is reachable and almost nothing is checked: a backend
//! could contain an outright type error and the object would still build. I
//! found this out the way one does -- `check` passed for every target, and
//! then the macOS runner refused to compile `std.atomic.Value(?CFRunLoopRef)`,
//! because `CFRunLoopRef` is already an optional pointer and
//! `std.atomic.Value` is an `extern struct`, which cannot hold a double
//! optional. Eight green objects had said nothing about it.
//!
//! `std.testing.refAllDecls` is no help here: its first line is `if
//! (!builtin.is_test) return;`, so outside a test build it does nothing at
//! all.
//!
//! So this does both halves by hand. Taking the address of a declaration
//! forces a function's body to be analyzed, and asking for a type's size
//! forces its fields to be resolved -- which is the half that catches a field
//! whose type is illegal on one target and fine on another.

const std = @import("std");
const hidapi = @import("hidapi");

comptime {
    force(hidapi);
}

/// Reference every declaration of `T`, and recurse one level into the
/// container types among them.
///
/// One level rather than all the way down: everything this library exposes is
/// reachable from the root or from one of the types it names, and an
/// unbounded walk wanders into `std` by way of a re-export and takes a long
/// time to come back.
fn force(comptime T: type) void {
    @setEvalBranchQuota(100_000);
    inline for (comptime std.meta.declarations(T)) |decl| {
        const field = &@field(T, decl.name);
        _ = field;
        if (@TypeOf(@field(T, decl.name)) == type) {
            forceType(@field(T, decl.name));
        }
    }
}

fn forceType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {
            // Resolving the size resolves every field, which is what an
            // object build otherwise never does.
            _ = @sizeOf(T);
            inline for (comptime std.meta.declarations(T)) |decl| {
                _ = &@field(T, decl.name);
            }
        },
        else => {},
    }
}
