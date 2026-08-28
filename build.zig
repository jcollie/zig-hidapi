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
            .root_module = module,
        },
    );

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

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
}
