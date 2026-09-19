// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A bounded ring of input reports, written by IOKit's callback and read by
//! `Device.read`.
//!
//! macOS cannot do a blocking read from the caller's thread at all: input
//! reports arrive as a callback on a `CFRunLoop`, whether anyone is reading or
//! not, so a device has to buffer from the moment it is opened. This is that
//! buffer. The storage is the caller's, handed in through
//! `OpenOptions.input_queue`, which is what keeps the library from allocating.
//!
//! Not `std.Io.Queue`, for two reasons. Its element type is comptime where a
//! slot here is `2 + max_report_len` bytes and the length is only known when
//! the device is opened; and dropping to `TypeErasedQueue` to get runtime
//! sizing brings a worse problem, because `put` with a minimum of zero queues
//! as much as fits and would happily queue half a report. A ring with an
//! explicit slot size cannot do that.
//!
//! Waiting is an epoch counter woken with `io.futexWake` and waited on with
//! `io.futexWaitTimeout`, which is how `Io.Condition` is built internally
//! (`Io.zig:1653`) plus the timeout `Condition` does not expose. That timeout
//! is the whole reason for hand-rolling it: `readTimeout` needs one.
//!
//! The critical section contains nothing but integer arithmetic and one
//! `@memcpy`. That is a rule rather than an accident: the producer runs inside
//! a `CFRunLoop` callback, and anything that could suspend there would stall
//! event delivery for every device sharing that run loop.

const ReportQueue = @This();

const std = @import("std");

mutex: std.Io.Mutex = .init,
/// Bumped on every push and on close; the word waiters sleep on.
epoch: std.atomic.Value(u32) = .init(0),
closed: std.atomic.Value(bool) = .init(false),

/// The caller's buffer, carved into `capacity` slots of `slot_len`.
slab: []u8,
slot_len: usize,
max_report_len: usize,
capacity: usize,

/// Index of the oldest queued report, and how many are queued.
head: usize = 0,
len: usize = 0,

/// Reports thrown away because the ring was full.
///
/// Counted rather than ignored. The C hidapi caps its list at 30 and drops
/// silently, which turns "my program is too slow" into "my device is flaky".
dropped: std.atomic.Value(u64) = .init(0),

/// Two bytes of length ahead of each report's bytes.
const header_len = 2;

/// How many reports of `max_report_len` bytes `buffer` can hold.
pub fn capacityFor(buffer_len: usize, max_report_len: usize) usize {
    const slot = header_len + max_report_len;
    return buffer_len / slot;
}

/// The smallest buffer that holds `count` reports of `max_report_len`.
pub fn bufferSizeFor(count: usize, max_report_len: usize) usize {
    return count * (header_len + max_report_len);
}

/// Returns `error.BufferTooSmall` when `buffer` cannot hold even one report,
/// which is the only size that is definitely wrong.
pub fn init(buffer: []u8, max_report_len: usize) error{BufferTooSmall}!ReportQueue {
    const slot_len = header_len + max_report_len;
    const capacity = buffer.len / slot_len;
    if (capacity == 0) return error.BufferTooSmall;
    return .{
        .slab = buffer[0 .. capacity * slot_len],
        .slot_len = slot_len,
        .max_report_len = max_report_len,
        .capacity = capacity,
    };
}

/// Queue a report, dropping the oldest if there is no room.
///
/// Dropping the oldest rather than the newest is deliberate: a program that
/// has fallen behind almost always wants the most recent state of a device,
/// not the state it was in when the program stopped keeping up.
///
/// Never fails and never blocks for longer than one `@memcpy`, because it is
/// called from IOKit's callback.
pub fn push(q: *ReportQueue, io: std.Io, bytes: []const u8) void {
    if (q.closed.load(.acquire)) return;
    const n = @min(bytes.len, q.max_report_len);

    q.mutex.lockUncancelable(io);
    if (q.len == q.capacity) {
        q.head = (q.head + 1) % q.capacity;
        q.len -= 1;
        _ = q.dropped.fetchAdd(1, .monotonic);
    }
    const slot_index = (q.head + q.len) % q.capacity;
    const slot = q.slab[slot_index * q.slot_len ..][0..q.slot_len];
    std.mem.writeInt(u16, slot[0..header_len], @intCast(n), .little);
    @memcpy(slot[header_len..][0..n], bytes[0..n]);
    q.len += 1;
    q.mutex.unlock(io);

    _ = q.epoch.fetchAdd(1, .release);
    io.futexWake(u32, &q.epoch.raw, std.math.maxInt(u32));
}

/// Take the oldest report, or `null` when there is none.
///
/// A zero-length report is a legal thing for a device to send, so this returns
/// an optional slice rather than a length, and `null` means empty rather than
/// "a report of no bytes".
pub fn pop(q: *ReportQueue, io: std.Io, out: []u8) ?[]u8 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);

    if (q.len == 0) return null;
    const slot = q.slab[q.head * q.slot_len ..][0..q.slot_len];
    const n = @min(@as(usize, std.mem.readInt(u16, slot[0..header_len], .little)), out.len);
    @memcpy(out[0..n], slot[header_len..][0..n]);
    q.head = (q.head + 1) % q.capacity;
    q.len -= 1;
    return out[0..n];
}

/// Refuse further reports and wake everyone waiting, so that a reader blocked
/// on a device that has gone away finds out rather than waiting forever.
pub fn close(q: *ReportQueue, io: std.Io) void {
    q.closed.store(true, .release);
    _ = q.epoch.fetchAdd(1, .release);
    io.futexWake(u32, &q.epoch.raw, std.math.maxInt(u32));
}

/// How many reports have been dropped since the last time this was asked,
/// resetting the count.
pub fn takeDropped(q: *ReportQueue) u64 {
    return q.dropped.swap(0, .monotonic);
}

test "a report round trips" {
    const io = std.testing.io;
    var buf: [3 * (2 + 8)]u8 = undefined;
    var q: ReportQueue = try .init(&buf, 8);

    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]u8, null), q.pop(io, &out));

    q.push(io, &[_]u8{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, q.pop(io, &out).?);
    try std.testing.expectEqual(@as(?[]u8, null), q.pop(io, &out));
}

test "a full ring drops the oldest and says so" {
    const io = std.testing.io;
    var buf: [2 * (2 + 4)]u8 = undefined;
    var q: ReportQueue = try .init(&buf, 4);
    try std.testing.expectEqual(@as(usize, 2), q.capacity);

    q.push(io, &[_]u8{1});
    q.push(io, &[_]u8{2});
    q.push(io, &[_]u8{3}); // pushes 1 out

    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{2}, q.pop(io, &out).?);
    try std.testing.expectEqualSlices(u8, &.{3}, q.pop(io, &out).?);
    try std.testing.expectEqual(@as(u64, 1), q.takeDropped());
    // Reading the count clears it.
    try std.testing.expectEqual(@as(u64, 0), q.takeDropped());
}

test "a report longer than the slot is truncated rather than overrunning" {
    const io = std.testing.io;
    var buf: [1 * (2 + 4)]u8 = undefined;
    var q: ReportQueue = try .init(&buf, 4);

    q.push(io, &[_]u8{ 1, 2, 3, 4, 5, 6 });
    var out: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, q.pop(io, &out).?);
}

test "an empty report is not the same as no report" {
    const io = std.testing.io;
    var buf: [2 * (2 + 4)]u8 = undefined;
    var q: ReportQueue = try .init(&buf, 4);

    q.push(io, &.{});
    var out: [4]u8 = undefined;
    const got = q.pop(io, &out);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(usize, 0), got.?.len);
}

test "a buffer too small for one report is refused" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, ReportQueue.init(&buf, 64));

    try std.testing.expectEqual(@as(usize, 4), capacityFor(4 * (2 + 8), 8));
    try std.testing.expectEqual(@as(usize, 40), bufferSizeFor(4, 8));
}

test "closing wakes readers and refuses more" {
    const io = std.testing.io;
    var buf: [2 * (2 + 4)]u8 = undefined;
    var q: ReportQueue = try .init(&buf, 4);

    q.close(io);
    q.push(io, &[_]u8{1});
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]u8, null), q.pop(io, &out));
}

test {
    std.testing.refAllDecls(@This());
}
