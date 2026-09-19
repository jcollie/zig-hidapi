// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What a backend has to provide, and the check that it does.
//!
//! A backend is a single file under `src/backend/` implementing one operating
//! system's way of talking to HID devices. `backend.zig` picks one at compile
//! time; every other file in the library goes through `Device`, which forwards
//! here. Nothing outside `src/backend/` names an operating system.
//!
//! The check below looks at declaration *names* and not at their types. A
//! signature comparison sounds stricter and is worse in practice: a backend
//! whose error set is inferred slightly differently fails it for no reason,
//! and the message it produces is further from the problem than the one the
//! call site gives on its own. What actually checks the signatures is `Device`
//! calling every one of these, which `zig build check` compiles for every
//! supported target.

const std = @import("std");

/// The declarations `Device` reaches for, in the order it needs them.
pub const required = [_][]const u8{
    // The open device itself.
    "Handle",
    "Minor",
    "open",
    "close",

    // The two endpoints that carry reports without a control transfer.
    "read",
    "write",

    // Everything that goes over the control endpoint.
    "getFeatureReport",
    "sendFeatureReport",
    "getInputReport",

    // What the device says about itself.
    "getReportDescriptorSize",
    "getReportDescriptor",
    "getRawName",
    "getRawUniq",
    "getPhysicalLocation",
    "getDeviceInfo",

    // The types those last two hand back.
    "BUS",
    "DevInfo",
};

/// Fail the build, naming the missing declaration, if `impl` is not a complete
/// backend. Called from `backend.zig` at container scope so that it runs for
/// whichever backend was selected, whether or not anything calls into it yet.
pub fn check(comptime impl: type) void {
    comptime {
        for (required) |name| {
            if (!@hasDecl(impl, name)) @compileError(
                "backend " ++ @typeName(impl) ++ " is missing `" ++ name ++
                    "`; every declaration in src/backend/contract.zig has to be present",
            );
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "the selected backend satisfies the contract" {
    // `backend.zig` already runs this at container scope, so reaching it here
    // proves only that the list above is not empty and that `check` compiles
    // when called from somewhere other than its one real call site.
    try std.testing.expect(required.len > 0);
    check(@import("../backend.zig").impl);
}
