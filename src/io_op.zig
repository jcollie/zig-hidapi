// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A safe `operateTimeout`, and the reason this library does not call
//! `std.Io.operateTimeout`.
//!
//! `std.Io.operateTimeout` builds a `Batch` over a stack array, submits one
//! operation, and waits:
//!
//! ```
//! var storage: [1]Operation.Storage = undefined;
//! var batch: Batch = .init(&storage);
//! batch.addAt(0, operation);
//! try batch.awaitConcurrent(io, timeout);   // <-- returns without cancelling
//! ```
//!
//! On `error.Timeout` that `try` returns and `storage` goes out of scope with
//! the operation still pending. On Windows an operation is pending in the
//! kernel's sense: `Io.Threaded` hands `NtReadFile` a pointer to the
//! `IO_STATUS_BLOCK` inside that array, along with an APC that will write
//! through it when the read completes. Returning leaves the kernel holding a
//! pointer into a dead stack frame.
//!
//! `Batch.cancel` is the remedy and `Batch.init`'s own documentation points at
//! it -- "after calling this, it is safe to unconditionally defer a call to
//! `cancel`" -- and cancel "waits for all pending operations to complete", so
//! after it the storage is nobody's but ours. One `defer` is the whole
//! difference.
//!
//! This should go upstream; when it does, this file can go.

const std = @import("std");

/// Perform one operation, giving up after `timeout`.
///
/// Identical to `std.Io.operateTimeout` except that it cancels the batch
/// before returning, which is what makes it safe to abandon a pending
/// operation whose storage lives on this stack frame.
pub fn operateTimeout(
    io: std.Io,
    operation: std.Io.Operation,
    timeout: std.Io.Timeout,
) std.Io.OperateTimeoutError!std.Io.Operation.Result {
    var storage: [1]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(&storage);
    // Unconditional, so it covers `error.Timeout` and `error.Canceled` alike.
    // Harmless on the success path: cancel has nothing pending to interrupt
    // once the one operation has completed, and the result has already been
    // copied out of the batch by the time this runs.
    defer batch.cancel(io);

    batch.addAt(0, operation);
    try batch.awaitConcurrent(io, timeout);

    const completion = batch.next().?;
    std.debug.assert(completion.index == 0);
    return completion.result;
}

test "a timeout that expires reports it rather than waiting" {
    const io = std.testing.io;

    // A pipe nobody writes to, read with a timeout that has already passed.
    // Under `Io.Threaded` this exercises the path the doc comment is about:
    // the read is still outstanding when the timeout fires.
    var fds: [2]std.os.linux.fd_t = undefined;
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{})) != .SUCCESS) return error.SkipZigTest;
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    var buf: [8]u8 = undefined;
    const result = operateTimeout(
        io,
        .{ .file_read_streaming = .{
            .file = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .data = &.{&buf},
        } },
        .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } },
    );
    try std.testing.expectError(error.Timeout, result);
}

test "a timeout that does not expire returns the operation's result" {
    const io = std.testing.io;
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var fds: [2]std.os.linux.fd_t = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{})) != .SUCCESS) return error.SkipZigTest;
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }
    const payload = "hello";
    _ = std.os.linux.write(fds[1], payload, payload.len);

    var buf: [8]u8 = undefined;
    const result = try operateTimeout(
        io,
        .{ .file_read_streaming = .{
            .file = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .data = &.{&buf},
        } },
        .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    );
    try std.testing.expectEqual(@as(usize, payload.len), try result.file_read_streaming);
    try std.testing.expectEqualStrings(payload, buf[0..payload.len]);
}

test {
    std.testing.refAllDecls(@This());
}
