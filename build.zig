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
