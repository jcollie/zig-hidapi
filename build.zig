// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("hidapi", .{
        .root_source_file = b.path("src/hidapi.zig"),
        .target = target,
        .optimize = optimize,
    });
    configure(b, module, true);

    const unit_tests = b.addTest(
        .{
            .name = "unit-tests",
            .root_module = module,
        },
    );

    // The test executables, installed rather than run, so that something
    // other than the build runner can run them -- specifically the NixOS
    // virtual machine test, which runs them as root because that is what
    // `/dev/uhid` needs. `zig build test` still builds and runs them in
    // place; this step only adds a copy in `zig-out/bin`.
    const test_exe_step = b.step("test-exe", "Install the test executables into zig-out/bin");
    test_exe_step.dependOn(&b.addInstallArtifact(unit_tests, .{}).step);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Tests that invent a HID device through Linux's `uhid` and then talk to
    // it through this library, which is the only way the suite gets to assert
    // anything exact: everything the device reports is something the test told
    // the kernel to report. They live outside `src/` so that the `uhid`
    // protocol does not end up in the published module or its documentation.
    //
    // `/dev/uhid` is root-only, so they report `SkipZigTest` on a developer's
    // machine and do their work in the NixOS virtual machine test.
    if (target.result.os.tag == .linux) {
        const virtual_device_tests = b.addTest(
            .{
                .name = "virtual-device-tests",
                .root_module = b.createModule(
                    .{
                        .root_source_file = b.path("tests/virtual_device.zig"),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{
                            .{ .name = "hidapi", .module = module },
                        },
                    },
                ),
            },
        );
        test_step.dependOn(&b.addRunArtifact(virtual_device_tests).step);
        test_exe_step.dependOn(&b.addInstallArtifact(virtual_device_tests, .{}).step);
    }

    const docs_obj = b.addObject(
        .{
            .name = "hidapi",
            .root_module = module,
        },
    );

    const install_docs = b.addInstallDirectory(
        .{
            .source_dir = docs_obj.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        },
    );

    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);

    // The generated viewer fetches `sources.tar` and `main.wasm` at runtime,
    // which a browser refuses to do from a `file://` page, so reading the docs
    // locally means serving them. This is the same reason `zig std` runs a
    // server rather than just opening a file.
    const docs_port = b.option(
        u16,
        "docs-port",
        "Port for `zig build docs-serve` (default 8000)",
    ) orelse 8000;

    const docs_server = b.addExecutable(
        .{
            .name = "docs-server",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("tools/docs_server.zig"),
                    // Always built for the machine running the build, never
                    // for whatever `-Dtarget` the library is being built for.
                    .target = b.graph.host,
                    .optimize = .Debug,
                },
            ),
        },
    );

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // The server runs until interrupted, so its output has to reach the
    // terminal rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // Only when this is the root package. A dependent's build runs this
    // script too, and constructing the cross-target check reaches for every
    // backend's dependencies -- which for Windows means fetching 7 MB of
    // generated Win32 bindings. A Linux program that merely uses this library
    // should not pay that for a step it will never run.
    //
    // `pkg_hash` is empty for the root package and is the hash of the package
    // otherwise, which is exactly the distinction wanted.
    if (b.pkg_hash.len == 0) addCheckStep(b, optimize, docs_server);

    // The server has tests of its own; without this they would never run.
    // Only in a Debug build, though: its module is pinned to Debug whatever
    // -Doptimize asks for, since it runs on the machine doing the build, so
    // running it again under ReleaseSafe and ReleaseFast would test the same
    // binary a second and third time. CI runs the suite in all three modes and
    // this keeps the two release runs to the library itself.
    if (optimize == .Debug) {
        const docs_server_tests = b.addTest(
            .{
                .root_module = docs_server.root_module,
            },
        );
        test_step.dependOn(&b.addRunArtifact(docs_server_tests).step);
    }
}

/// Everything about the module that depends on which operating system it is
/// being built for.
///
/// Called once for the published module and once per target in the `check`
/// step below, so that what CI compiles and what a dependent compiles cannot
/// drift apart.
///
/// Note what is deliberately *not* here: an unsupported operating system is
/// not a `@compileError` in this file. `src/backend.zig` produces that
/// message, so a dependent that adds the module without going through this
/// `build.zig` fails the same way and reads the same explanation, rather than
/// getting a worse one from somewhere inside `Device`.
fn configure(b: *std.Build, module: *std.Build.Module, link: bool) void {
    switch (module.resolved_target.?.result.os.tag) {
        // Every syscall goes through `std.os.linux`, so a Linux build links
        // no C at all. The other backends will not have that luxury: Zig 0.16
        // ships no raw-syscall layer for FreeBSD or Darwin, and Windows has
        // none to ship.
        .linux => {},

        // Zig 0.16 ships no raw-syscall layer for FreeBSD -- `std/os/` has
        // linux, windows, plan9, uefi and wasi and nothing else -- so every
        // syscall goes through `std.c` and this target has to link libc.
        // Nothing in the backend calls libc directly; `std.Io` does.
        .freebsd => module.link_libc = true,

        // `NtDeviceIoControlFile` comes from std, so the only thing needed
        // here is the generated Win32 bindings. They are a lazy dependency,
        // which is what keeps a Linux build from fetching them.
        //
        // `pic` is not optional. An `extern "hid"` reference in a build that
        // does not link -- which is exactly what the `check` step below does
        // -- is refused with "dependency on dynamic library 'hid' requires
        // enabling Position Independent Code", and naming the library instead
        // does not work there, because the import library is only generated
        // for a real link step.
        .windows => {
            module.pic = true;
            if (b.lazyDependency("win32", .{})) |dep| {
                module.addImport("win32", dep.module("win32"));
            }
        },

        // Like FreeBSD, Darwin has no raw-syscall layer in `std/os`, so it
        // goes through `std.c`. IOKit is the only way to reach a HID device
        // on macOS, and CoreFoundation comes with it.
        //
        // Linking a framework needs a macOS SDK, which a Linux machine does
        // not have -- which is exactly why `check` below builds objects and
        // never links. `link_libc` and the declarations themselves need no
        // SDK at all, so the backend still compiles anywhere.
        .macos, .ios, .tvos, .watchos, .visionos => {
            module.link_libc = true;
            if (link) {
                module.linkFramework("CoreFoundation", .{});
                module.linkFramework("IOKit", .{});
            }
        },

        else => {},
    }
}

/// The targets `zig build check` compiles for, given whether the Windows
/// bindings may be fetched.
///
/// Two architectures per system, not one. The ioctl request number's length
/// field is 14 bits on most architectures and 13 on the ones that spend an
/// extra bit on the direction, and pointer width varies, so a backend can
/// compile on one and not the other.
const checked_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
    .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
    // `-gnu` rather than `-msvc`: the MSVC ABI wants the Windows SDK's import
    // libraries, which a Linux machine does not have, while the GNU ABI uses
    // the mingw `.def` files Zig ships.
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

/// A step that compiles the library for every supported target without
/// linking it.
///
/// `addObject` rather than `addExecutable` or a linked library, and that is
/// the whole trick: no linker runs, so no framework, no import library and no
/// platform SDK has to be present. A Linux machine can therefore prove that
/// the Darwin backend still compiles, which it could not do any other way --
/// `zig build-lib -target aarch64-macos -framework IOKit` fails with "unable
/// to find framework 'IOKit'" unless a macOS SDK is in reach, while the same
/// build as an object succeeds.
///
/// What it does not prove is that the symbols exist. A misspelled
/// `IOHIDDeviceOpen` compiles here and fails to link on a Mac, which is what
/// the macOS and Windows runners on the GitHub mirror are for.
fn addCheckStep(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    docs_server: *std.Build.Step.Compile,
) void {
    const check_step = b.step("check", "Compile for every supported target without linking");

    // Building for Windows means reaching for the generated Win32 bindings,
    // and asking for them is what makes Zig fetch them -- about 7 MB
    // compressed. That is the right trade for a developer or for CI, and the
    // wrong one for a build that is only after the Linux test binaries and
    // has no network at all, which is exactly what the Nix build is.
    const check_windows = b.option(
        bool,
        "check-windows",
        "Include the Windows targets in `zig build check` (fetches the Win32 bindings)",
    ) orelse true;

    for (checked_targets) |query| {
        if (query.os_tag == .windows and !check_windows) continue;
        const target = b.resolveTargetQuery(query);
        const module = b.createModule(.{
            .root_source_file = b.path("src/hidapi.zig"),
            .target = target,
            .optimize = optimize,
        });
        // `link = false`: this module is compiled to an object and never
        // linked, so asking for a framework here would fail on any machine
        // without the SDK for it.
        configure(b, module, false);

        // Not the library module directly. Zig analyzes lazily and a library
        // exports no symbols, so compiling it alone reaches almost nothing --
        // `tools/check_root.zig` is what forces every declaration and every
        // field layout to be looked at. See the comment at the top of that
        // file for the bug that taught me the difference.
        const root = b.createModule(.{
            .root_source_file = b.path("tools/check_root.zig"),
            .target = target,
            .optimize = optimize,
        });
        root.addImport("hidapi", module);

        check_step.dependOn(&b.addObject(.{
            .name = b.fmt("hidapi-{t}-{t}", .{ query.cpu_arch.?, query.os_tag.? }),
            .root_module = root,
        }).step);
    }

    // Nothing else builds the documentation server except `docs-serve`, so
    // without this it can stop compiling and no test notices.
    check_step.dependOn(&docs_server.step);
}
