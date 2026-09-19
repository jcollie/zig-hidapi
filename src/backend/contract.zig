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

/// The declarations a backend's root has to carry.
pub const required = [_][]const u8{
    "Device",
    "Enumerator",
    "max_report_descriptor_len",
};

/// The methods `Device` forwards to.
pub const device_required = [_][]const u8{
    "open",
    "close",

    // The two endpoints that carry reports without a control transfer.
    "read",
    "readTimeout",
    "write",

    // Everything that goes over the control endpoint.
    "getFeatureReport",
    "sendFeatureReport",
    "getInputReport",

    // What the device says about itself.
    "getReportDescriptorLen",
    "getReportDescriptor",
    "getInfo",
};

/// The methods `Enumerator` forwards to, and the two sizes it republishes.
pub const enumerator_required = [_][]const u8{
    "init",
    "deinit",
    "next",
    "min_scratch",
    "recommended_scratch",
};

/// Fail the build, naming what is missing, if `impl` is not a complete
/// backend. Called from `backend.zig` at container scope so that it runs for
/// whichever backend was selected, whether or not anything calls into it yet.
pub fn check(comptime impl: type) void {
    comptime {
        expect(impl, "backend", &required);
        if (@hasDecl(impl, "Device")) expect(impl.Device, "backend Device", &device_required);
        if (@hasDecl(impl, "Enumerator")) expect(impl.Enumerator, "backend Enumerator", &enumerator_required);
    }
}

fn expect(comptime T: type, comptime what: []const u8, comptime names: []const []const u8) void {
    comptime {
        for (names) |name| {
            if (!@hasDecl(T, name)) @compileError(
                what ++ " " ++ @typeName(T) ++ " is missing `" ++ name ++
                    "`; the full list is in src/backend/contract.zig",
            );
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "the selected backend satisfies the contract" {
    // `backend.zig` already runs this at container scope, so reaching it here
    // proves only that the lists above are not empty and that `check` compiles
    // when called from somewhere other than its one real call site.
    try std.testing.expect(required.len > 0);
    try std.testing.expect(device_required.len > 0);
    try std.testing.expect(enumerator_required.len > 0);
    check(@import("../backend.zig").impl);
}
