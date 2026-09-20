// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The macOS backend: IOKit's HID Manager.
//!
//! This backend is shaped differently from the other three, because macOS is.
//! There is no device node and no ioctl: a device is an `IOHIDDeviceRef` from
//! the I/O Registry, and **input reports arrive on a callback**, delivered by
//! a `CFRunLoop`, whether anyone is reading or not. So an open device owns a
//! task running a run loop and a queue for what that callback delivers, from
//! `open` until `close`. There is no way to do a blocking read on the caller's
//! thread instead; this is not an optimisation.
//!
//! Three consequences a caller can see:
//!
//! * Each open device holds one unit of concurrency for its whole life, so an
//!   `Io` with a bounded `concurrent_limit` can refuse to open one. That is
//!   why `Io.ConcurrentError` is in `OpenError` on every target.
//! * The queue is bounded, and a program that falls behind loses reports.
//!   `takeDroppedReports` says how many, because losing input silently is
//!   worse than losing it loudly.
//! * `OpenOptions.input_queue` is required here, where the other three
//!   backends ignore it. Without a buffer there is nowhere to put a report
//!   that arrives between reads.
//!
//! `IOHIDDeviceSetReport` and `GetReport` are synchronous IOKit calls with no
//! `Io.Operation` behind them, so they go through `io.concurrent` and **cannot
//! be cancelled** -- cancellation is only delivered at a call into `Io`, and
//! those are calls into IOKit. `OpenOptions.request_timeout` bounds them
//! instead, by way of `kIOHIDRequestTimeoutKey`, so that a wedged device
//! cannot hold a task forever.
//!
//! Zig 0.16 ships no raw-syscall layer for Darwin, so this backend links libc,
//! and it links the IOKit and CoreFoundation frameworks. Neither is needed to
//! *compile* it, which is what lets `zig build check` build this file on a
//! Linux machine with no macOS SDK -- the only coverage it has until it runs
//! on a real Mac.

const std = @import("std");

const cf = @import("darwin/cf.zig");
const iokit = @import("darwin/iokit.zig");
const ReportQueue = @import("darwin/ReportQueue.zig");
const naming = @import("darwin/naming.zig");

const descriptor = @import("../descriptor.zig");
const errors = @import("../errors.zig");
const BusType = @import("../bus_type.zig").BusType;
const DeviceId = @import("../DeviceId.zig");
const DeviceInfo = @import("../DeviceInfo.zig");
const Options = @import("../Enumerator.zig").Options;
const OpenOptions = @import("../Device.zig").OpenOptions;
const Str = @import("../Str.zig");

const log = std.log.scoped(.hidapi_darwin);

/// The largest report descriptor this library will copy out.
pub const max_report_descriptor_len = 4096;

/// Zero: IOKit publishes the descriptor itself, so there is nothing to
/// rebuild and nowhere to need working memory.
pub const recommended_descriptor_scratch = 0;

/// Map an `IOReturn` onto the portable error set, logging what it was.
fn mapReturn(what: []const u8, rc: iokit.IOReturn) errors.DeviceError {
    log.warn("{s}: IOReturn 0x{x}", .{ what, @as(u32, @bitCast(rc)) });
    return switch (@as(u32, @bitCast(rc))) {
        // kIOReturnNotPermitted, kIOReturnNotPrivileged, kIOReturnExclusiveAccess.
        // On macOS 10.15 and later the first of these is usually not a
        // permissions bug in the ordinary sense: it means the process has not
        // been granted Input Monitoring.
        0xE00002E2, 0xE00002C1, 0xE00002C5 => error.AccessDenied,
        // kIOReturnNoDevice
        0xE00002C0 => error.DeviceNotFound,
        // kIOReturnNotAttached, kIOReturnOffline
        0xE00002D0, 0xE00002FE => error.DeviceDisconnected,
        // kIOReturnNoMemory, kIOReturnNoResources
        0xE00002BD, 0xE00002BE => error.SystemResources,
        else => error.DeviceRefused,
    };
}

/// A CoreFoundation string built from a Zig one, for a property key.
fn key(name: [:0]const u8) cf.CFStringRef {
    return cf.CFStringCreateWithCString(cf.kCFAllocatorDefault, name.ptr, cf.kCFStringEncodingUTF8);
}

/// Read a property, releasing the key afterwards.
fn property(device: iokit.IOHIDDeviceRef, name: [:0]const u8) cf.CFTypeRef {
    const k = key(name);
    defer if (k != null) cf.CFRelease(k);
    return iokit.IOHIDDeviceGetProperty(device, k);
}

fn intProperty(device: iokit.IOHIDDeviceRef, name: [:0]const u8) ?i32 {
    return cf.intValue(property(device, name));
}

fn strProperty(device: iokit.IOHIDDeviceRef, name: [:0]const u8) Str {
    var buf: [Str.max_len]u8 = undefined;
    const text = cf.stringValue(property(device, name), &buf) orelse return .empty;
    return .init(text);
}

/// Fill in what a device's properties say, without opening it.
fn describe(device: iokit.IOHIDDeviceRef, options: Options, out: *DeviceInfo) void {
    out.* = .empty;

    if (intProperty(device, iokit.kIOHIDVendorIDKey)) |v| out.vendor_id = @truncate(@as(u32, @bitCast(v)));
    if (intProperty(device, iokit.kIOHIDProductIDKey)) |v| out.product_id = @truncate(@as(u32, @bitCast(v)));
    if (intProperty(device, iokit.kIOHIDVersionNumberKey)) |v| out.release_number = @truncate(@as(u32, @bitCast(v)));

    if (options.usages) {
        if (intProperty(device, iokit.kIOHIDPrimaryUsagePageKey)) |v| out.usage_page = @truncate(@as(u32, @bitCast(v)));
        if (intProperty(device, iokit.kIOHIDPrimaryUsageKey)) |v| out.usage = @truncate(@as(u32, @bitCast(v)));
    }

    {
        var buf: [64]u8 = undefined;
        const transport = cf.stringValue(property(device, iokit.kIOHIDTransportKey), &buf) orelse "";
        out.bus_type = naming.busTypeFromTransport(transport);
    }

    if (options.strings) {
        out.manufacturer = strProperty(device, iokit.kIOHIDManufacturerKey);
        out.product = strProperty(device, iokit.kIOHIDProductKey);
        out.serial_number = strProperty(device, iokit.kIOHIDSerialNumberKey);

        // IOKit has no "where is it plugged in" string. The location ID is
        // the nearest thing: a number identifying the port, stable across
        // replugs into the same one, which is the question
        // `physical_location` answers everywhere else.
        if (intProperty(device, iokit.kIOHIDLocationIDKey)) |loc| {
            var buf: [24]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "0x{x:0>8}", .{@as(u32, @bitCast(loc))})) |text| {
                out.physical_location = .init(text);
            } else |_| {}
        }
    }
}

/// An open HID device, its reader task, and the queue between them.
pub const Device = struct {
    handle: iokit.IOHIDDeviceRef,
    entry_id: u64,
    open_options: iokit.IOOptionBits,

    /// The buffer IOKit writes each incoming report into, before the callback
    /// copies it into the queue. Carved out of the caller's `input_queue`.
    report_buf: []u8,
    queue: ReportQueue,

    /// The task running this device's run loop, and the signals that start
    /// and stop it.
    reader: std.Io.Future(void),
    started: std.Io.Event,
    /// Held until `close` has finished signalling the run loop, because the
    /// signal dereferences `source` and `run_loop` and the task must not
    /// return and let them be released first.
    may_finish: std.Io.Event,

    /// A per-device run loop mode.
    ///
    /// Load-bearing, not decoration. `Io.Threaded` pools threads, so two
    /// devices can be given the same thread and therefore the same
    /// `CFRunLoopRef`; a mode of their own keeps their sources and their
    /// `CFRunLoopRunInMode` calls from seeing each other. The C hidapi uses
    /// the device pointer to make the name unique; the registry entry ID is
    /// stable and does not leak an address.
    mode: cf.CFStringRef,
    source: cf.CFRunLoopSourceRef,
    /// `CFRunLoopRef` is already `?*anyopaque`, so this is *not* wrapped in
    /// another optional: `std.atomic.Value` is an `extern struct`, and a
    /// double optional has no guaranteed in-memory representation to put in
    /// one. `null` means the reader task has not published it yet.
    run_loop: std.atomic.Value(cf.CFRunLoopRef),

    shutdown: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),

    /// The `Io` the device was opened with.
    ///
    /// Kept because IOKit's callback signature has nowhere to put one and the
    /// callback has to reach the queue.
    io: std.Io,

    pub fn open(
        self: *Device,
        io: std.Io,
        id: DeviceId,
        options: OpenOptions,
    ) errors.OpenError!void {
        const entry_id = naming.parseId(id.slice()) orelse return error.DeviceNotFound;

        const service = iokit.IOServiceGetMatchingService(
            iokit.null_port,
            iokit.IORegistryEntryIDMatching(entry_id),
        );
        if (service == 0) return error.DeviceNotFound;
        defer _ = iokit.IOObjectRelease(service);

        const handle = iokit.IOHIDDeviceCreate(cf.kCFAllocatorDefault, service);
        if (handle == null) return error.DeviceNotFound;
        errdefer cf.CFRelease(handle);

        const open_options: iokit.IOOptionBits = if (options.exclusive)
            iokit.kIOHIDOptionsTypeSeizeDevice
        else
            iokit.kIOHIDOptionsTypeNone;

        const rc = iokit.IOHIDDeviceOpen(handle, open_options);
        if (rc != iokit.kIOReturnSuccess) return mapReturn("IOHIDDeviceOpen", rc);
        errdefer _ = iokit.IOHIDDeviceClose(handle, open_options);

        // How big an input report this device sends, which is how the queue's
        // slots are sized. A device that will not say gets a slot big enough
        // for anything HID allows.
        const max_input: usize = if (intProperty(handle, iokit.kIOHIDMaxInputReportSizeKey)) |v|
            @intCast(@max(v, 1))
        else
            64;

        // The caller's buffer has to hold the queue *and* the single report
        // buffer IOKit writes into.
        if (options.input_queue.len <= max_input) return error.BufferTooSmall;
        const report_buf = options.input_queue[0..max_input];
        const queue: ReportQueue = try .init(options.input_queue[max_input..], max_input);

        // Bound the synchronous requests, which cannot be cancelled.
        if (options.request_timeout.toDurationFromNow(io)) |d| {
            const micros: i32 = @intCast(@min(d.raw.toMicroseconds(), std.math.maxInt(i32)));
            const k = key(iokit.kIOHIDRequestTimeoutKey);
            defer if (k != null) cf.CFRelease(k);
            var number = micros;
            _ = iokit.IOHIDDeviceSetProperty(handle, k, @ptrCast(&number));
        }

        var mode_buf: [64]u8 = undefined;
        const mode_name = std.fmt.bufPrintZ(&mode_buf, "zig-hidapi-{d}", .{entry_id}) catch
            return error.DeviceRefused;
        const mode = key(mode_name);
        if (mode == null) return error.SystemResources;
        errdefer cf.CFRelease(mode);

        self.* = .{
            .handle = handle,
            .entry_id = entry_id,
            .open_options = open_options,
            .report_buf = report_buf,
            .queue = queue,
            .reader = undefined,
            .started = .unset,
            .may_finish = .unset,
            .mode = mode,
            .source = null,
            .run_loop = .init(null),
            .shutdown = .init(false),
            .disconnected = .init(false),
            .io = io,
        };

        // Registered before the run loop starts, exactly as the C hidapi does:
        // a report that arrives in between is then queued rather than lost.
        iokit.IOHIDDeviceRegisterInputReportCallback(
            handle,
            self.report_buf.ptr,
            @intCast(self.report_buf.len),
            reportCallback,
            self,
        );
        iokit.IOHIDDeviceRegisterRemovalCallback(handle, removalCallback, self);

        self.reader = try io.concurrent(readLoop, .{self});
        // Do not return until the loop is live, so that a `read` immediately
        // after `open` cannot miss reports the device has already sent.
        self.started.wait(io) catch {};
    }

    /// The reader task: owns a `CFRunLoop` and pumps it until told to stop.
    fn readLoop(self: *Device) void {
        const io = self.io;
        const run_loop = cf.CFRunLoopGetCurrent();
        self.run_loop.store(run_loop, .release);

        iokit.IOHIDDeviceScheduleWithRunLoop(self.handle, run_loop, self.mode);

        var context: cf.CFRunLoopSourceContext = .{ .info = self, .perform = performWake };
        self.source = cf.CFRunLoopSourceCreate(cf.kCFAllocatorDefault, 0, &context);
        cf.CFRunLoopAddSource(run_loop, self.source, self.mode);

        self.started.set(io);

        while (!self.shutdown.load(.acquire)) {
            switch (cf.CFRunLoopRunInMode(self.mode, 1000.0, 0)) {
                .finished, .stopped => break,
                .timed_out, .handled_source => {},
                _ => break,
            }
        }

        // Wake anyone blocked in `read`, who would otherwise wait for a
        // report that is never coming.
        self.queue.close(io);
        // `close` signals the source and the run loop after setting
        // `shutdown`, and both of those dereference fields this task owns, so
        // it must not return until that has happened.
        self.may_finish.wait(io) catch {};
    }

    /// Runs on the reader task's own thread, as the run loop's source.
    fn performWake(info: ?*anyopaque) callconv(.c) void {
        const self: *Device = @ptrCast(@alignCast(info.?));
        if (self.run_loop.load(.acquire)) |run_loop| cf.CFRunLoopStop(run_loop);
    }

    /// Runs on the reader task's thread, from inside the run loop.
    ///
    /// `report` always aliases `self.report_buf`, so the bytes have to be
    /// copied before this returns.
    fn reportCallback(
        context: ?*anyopaque,
        result: iokit.IOReturn,
        sender: ?*anyopaque,
        report_type: iokit.IOHIDReportType,
        report_id: u32,
        report: [*]u8,
        report_length: cf.CFIndex,
    ) callconv(.c) void {
        _ = .{ sender, report_type, report_id };
        const self: *Device = @ptrCast(@alignCast(context.?));
        if (result != iokit.kIOReturnSuccess) return;
        if (report_length <= 0) return;
        self.queue.push(self.io, report[0..@intCast(report_length)]);
    }

    fn removalCallback(context: ?*anyopaque, result: iokit.IOReturn, sender: ?*anyopaque) callconv(.c) void {
        _ = .{ result, sender };
        const self: *Device = @ptrCast(@alignCast(context.?));
        self.disconnected.store(true, .release);
        self.shutdown.store(true, .release);
        if (self.run_loop.load(.acquire)) |run_loop| {
            cf.CFRunLoopSourceSignal(self.source);
            cf.CFRunLoopWakeUp(run_loop);
        }
    }

    /// Stop the reader, unregister, and let the device go.
    ///
    /// The order here is copied from the C hidapi and every step of it is
    /// load-bearing:
    ///
    /// * Unregistering the input callback and then **immediately rescheduling
    ///   the device on the main run loop** is the mitigation for
    ///   signal11/hidapi#116, where the HID Manager segfaults when the next
    ///   report arrives after an unregister. Rescheduling gives IOKit a live
    ///   run loop to deliver to instead of the dead one this device owned. If
    ///   the host program's main thread never runs a run loop, which is usual
    ///   for a command-line program, nothing is delivered -- which is
    ///   harmless, and is why this is safe rather than merely expedient.
    /// * Both that and `IOHIDDeviceClose` are skipped for a device that has
    ///   already been removed on a system older than 10.10, because calling
    ///   close on a removed device crashed there. Since 10.15 *not* calling it
    ///   can crash instead, hence the version test rather than a plain check
    ///   for removal. The C hidapi's comment says as much, and the boundary is
    ///   empirical rather than documented.
    /// * The reader is awaited, not cancelled. Cancellation is only delivered
    ///   at a call into `Io`, and the task is inside `CFRunLoopRunInMode`, so
    ///   cancelling would do nothing; stopping the run loop is what ends it.
    pub fn close(self: *Device, io: std.Io) void {
        const modern = cf.kCFCoreFoundationVersionNumber >= cf.version_10_10;
        const gone = self.disconnected.load(.acquire);

        if (modern or !gone) {
            iokit.IOHIDDeviceRegisterInputReportCallback(
                self.handle,
                self.report_buf.ptr,
                @intCast(self.report_buf.len),
                null,
                self,
            );
            iokit.IOHIDDeviceRegisterRemovalCallback(self.handle, null, self);
            if (self.run_loop.load(.acquire)) |run_loop| {
                iokit.IOHIDDeviceUnscheduleFromRunLoop(self.handle, run_loop, self.mode);
            }
            iokit.IOHIDDeviceScheduleWithRunLoop(
                self.handle,
                cf.CFRunLoopGetMain(),
                cf.kCFRunLoopDefaultMode,
            );
        }

        self.shutdown.store(true, .release);
        if (self.run_loop.load(.acquire)) |run_loop| {
            if (self.source != null) cf.CFRunLoopSourceSignal(self.source);
            cf.CFRunLoopWakeUp(run_loop);
        }
        self.may_finish.set(io);
        self.reader.await(io);

        if (modern or !gone) _ = iokit.IOHIDDeviceClose(self.handle, self.open_options);

        if (self.source != null) {
            cf.CFRunLoopSourceInvalidate(self.source);
            cf.CFRelease(self.source);
        }
        if (self.mode != null) cf.CFRelease(self.mode);
        cf.CFRelease(self.handle);
        self.handle = null;
    }

    pub fn read(self: *Device, io: std.Io, buf: []u8) errors.ReadError![]u8 {
        return (try self.waitForReport(io, buf, .none)) orelse error.DeviceDisconnected;
    }

    pub fn readTimeout(
        self: *Device,
        io: std.Io,
        buf: []u8,
        timeout: std.Io.Timeout,
    ) errors.ReadError!?[]u8 {
        return self.waitForReport(io, buf, timeout);
    }

    /// The whole read path.
    ///
    /// `null` means the timeout expired, or the device went away with nothing
    /// left queued -- the caller tells those apart by asking again and getting
    /// `error.DeviceDisconnected` from `read`.
    fn waitForReport(
        self: *Device,
        io: std.Io,
        buf: []u8,
        timeout: std.Io.Timeout,
    ) errors.ReadError!?[]u8 {
        // Computed once, deliberately. Recomputing a `.duration` inside the
        // loop would restart the clock on every spurious wake-up and turn a
        // ten millisecond timeout into an unbounded wait.
        const deadline = timeout.toDeadline(io);

        while (true) {
            // Snapshot the epoch *before* looking, so a report pushed between
            // the look and the wait cannot be missed.
            const epoch = self.queue.epoch.load(.acquire);

            if (self.queue.pop(io, buf)) |report| return report;
            if (self.queue.closed.load(.acquire)) return null;

            switch (deadline) {
                .none => {},
                else => {
                    const left = deadline.toDurationFromNow(io) orelse break;
                    if (left.raw.toNanoseconds() <= 0) return null;
                },
            }

            io.futexWaitTimeout(u32, &self.queue.epoch.raw, epoch, deadline) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
        }
        return null;
    }

    /// Reports dropped because the queue was full since this was last asked.
    pub fn takeDroppedReports(self: *Device) u64 {
        return self.queue.takeDropped();
    }

    pub fn write(self: *Device, io: std.Io, data: []const u8) errors.WriteError!usize {
        _ = try self.setReport(io, .output, data);
        return data.len;
    }

    pub fn sendFeatureReport(
        self: *Device,
        io: std.Io,
        data: []const u8,
    ) errors.ReportError!usize {
        _ = try self.setReport(io, .feature, data);
        return data.len;
    }

    pub fn getFeatureReport(self: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
        return self.getReport(io, .feature, buf);
    }

    pub fn getInputReport(self: *Device, io: std.Io, buf: []u8) errors.ReportError![]u8 {
        return self.getReport(io, .input, buf);
    }

    /// IOKit takes the report ID as an argument of its own, and expects the
    /// buffer *without* a leading ID byte for a device whose reports are
    /// unnumbered.
    ///
    /// This library's convention is hidapi's -- the first byte is always the
    /// report ID, zero when there are none -- so the leading zero is stripped
    /// here, and put back by `getReport`. That is what makes the bytes a
    /// caller sees the same on every system.
    fn setReport(
        self: *Device,
        io: std.Io,
        kind: iokit.IOHIDReportType,
        data: []const u8,
    ) errors.WriteError!void {
        // Every report carries a report ID byte, so an empty one is not a
        // report at all. `WriteError` rather than `ReportError` because that
        // is the narrower of the two and `sendFeatureReport` widens to the
        // other on its way out.
        if (data.len == 0) return error.ReportTooLarge;
        const report_id = data[0];
        const payload = if (report_id == 0) data[1..] else data;

        var p = io.concurrent(setReportBlocking, .{ self.handle, kind, report_id, payload }) catch
            return error.SystemResources;
        defer _ = p.cancel(io) catch {};
        return p.await(io);
    }

    fn getReport(
        self: *Device,
        io: std.Io,
        kind: iokit.IOHIDReportType,
        buf: []u8,
    ) errors.ReportError![]u8 {
        if (buf.len == 0) return error.BufferTooSmall;
        const report_id = buf[0];

        var p = io.concurrent(getReportBlocking, .{ self.handle, kind, report_id, buf[1..] }) catch
            return error.SystemResources;
        defer _ = p.cancel(io) catch {};
        const len = try p.await(io);
        return buf[0 .. len + 1];
    }

    /// The raw HID report descriptor.
    ///
    /// Unlike Windows, macOS does hand this over -- as a `CFData` under
    /// `kIOHIDReportDescriptorKey`. Apple documents that key only for
    /// DriverKit rather than for the user-space HID Manager, so this also
    /// looks at the underlying registry entry, which occasionally carries a
    /// property the device's own cache does not. A device that publishes it
    /// nowhere gets `error.Unsupported`, which is the honest answer.
    pub fn getReportDescriptor(
        self: *Device,
        io: std.Io,
        buf: []u8,
    ) errors.DescriptorError![]const u8 {
        _ = io;
        const bytes = self.descriptorBytes() orelse return error.Unsupported;
        if (buf.len < bytes.len) return error.BufferTooSmall;
        @memcpy(buf[0..bytes.len], bytes);
        return buf[0..bytes.len];
    }

    pub fn getReportDescriptorLen(self: *Device, io: std.Io) errors.DescriptorError!u32 {
        _ = io;
        const bytes = self.descriptorBytes() orelse return error.Unsupported;
        return @intCast(bytes.len);
    }

    /// The descriptor bytes, which alias CoreFoundation's own storage and are
    /// valid as long as the device is open.
    fn descriptorBytes(self: *Device) ?[]const u8 {
        if (cf.dataValue(property(self.handle, iokit.kIOHIDReportDescriptorKey))) |bytes| return bytes;

        // Second chance: the property table behind the service, rather than
        // the device object's cached copy.
        const service = iokit.IOHIDDeviceGetService(self.handle);
        if (service == 0) return null;
        const k = key(iokit.kIOHIDReportDescriptorKey);
        defer if (k != null) cf.CFRelease(k);
        const value = iokit.IORegistryEntryCreateCFProperty(service, k, cf.kCFAllocatorDefault, 0);
        return cf.dataValue(value);
    }

    pub fn getInfo(
        self: *Device,
        io: std.Io,
        out: *DeviceInfo,
    ) (errors.DeviceError || std.Io.Cancelable)!void {
        _ = io;
        describe(self.handle, .{}, out);
        var buf: [DeviceId.max_len]u8 = undefined;
        if (naming.formatId(self.entry_id, &buf)) |text| {
            out.id = DeviceId.init(text) catch .none;
        }
    }
};

fn setReportBlocking(
    handle: iokit.IOHIDDeviceRef,
    kind: iokit.IOHIDReportType,
    report_id: u8,
    payload: []const u8,
) errors.WriteError!void {
    const rc = iokit.IOHIDDeviceSetReport(
        handle,
        kind,
        report_id,
        payload.ptr,
        @intCast(payload.len),
    );
    if (rc != iokit.kIOReturnSuccess) return mapReturn("IOHIDDeviceSetReport", rc);
}

fn getReportBlocking(
    handle: iokit.IOHIDDeviceRef,
    kind: iokit.IOHIDReportType,
    report_id: u8,
    buf: []u8,
) errors.ReportError!usize {
    var len: cf.CFIndex = @intCast(buf.len);
    const rc = iokit.IOHIDDeviceGetReport(handle, kind, report_id, buf.ptr, &len);
    if (rc != iokit.kIOReturnSuccess) return mapReturn("IOHIDDeviceGetReport", rc);
    return @intCast(@max(len, 0));
}

/// Walks the HID devices IOKit knows about.
///
/// Deliberately does **not** call `IOHIDManagerOpen`, which would try to open
/// every HID device on the machine and is the thing most likely to provoke the
/// Input Monitoring consent dialog. Listing devices and reading their
/// properties needs no such permission; opening one does.
pub const Enumerator = struct {
    manager: iokit.IOHIDManagerRef,
    devices: []const iokit.IOHIDDeviceRef,
    index: usize,
    options: Options,

    /// Room for a few hundred devices' worth of pointers, which is far more
    /// than any real machine has.
    pub const recommended_scratch = 8 * 1024;
    pub const min_scratch = 512;

    pub fn init(
        self: *Enumerator,
        io: std.Io,
        scratch: []u8,
        options: Options,
    ) errors.EnumerateError!void {
        _ = io;
        if (scratch.len < min_scratch) return error.BufferTooSmall;

        self.* = .{ .manager = null, .devices = &.{}, .index = 0, .options = options };

        const manager = iokit.IOHIDManagerCreate(cf.kCFAllocatorDefault, iokit.kIOHIDOptionsTypeNone);
        if (manager == null) return error.SystemResources;
        // A null matching dictionary means "every HID device".
        iokit.IOHIDManagerSetDeviceMatching(manager, null);

        const set = iokit.IOHIDManagerCopyDevices(manager);
        if (set == null) {
            // No devices at all is an empty list rather than a failure.
            self.manager = manager;
            return;
        }
        defer cf.CFRelease(set);

        const count: usize = @intCast(@max(cf.CFSetGetCount(set), 0));
        const aligned = std.mem.alignInSlice(scratch, @alignOf(iokit.IOHIDDeviceRef)) orelse
            return error.BufferTooSmall;
        const slots = std.mem.bytesAsSlice(iokit.IOHIDDeviceRef, aligned);
        if (count > slots.len) return error.BufferTooSmall;

        cf.CFSetGetValues(set, @ptrCast(slots.ptr));

        self.* = .{
            .manager = manager,
            .devices = slots[0..count],
            .index = 0,
            .options = options,
        };
    }

    pub fn deinit(self: *Enumerator, io: std.Io) void {
        _ = io;
        if (self.manager != null) cf.CFRelease(self.manager);
        self.* = undefined;
    }

    pub fn next(
        self: *Enumerator,
        io: std.Io,
        out: *DeviceInfo,
    ) errors.EnumerateError!bool {
        _ = io;
        while (self.index < self.devices.len) {
            const device = self.devices[self.index];
            self.index += 1;

            describe(device, self.options, out);
            if (!out.matches(self.options.vendor_id, self.options.product_id)) continue;

            const service = iokit.IOHIDDeviceGetService(device);
            if (service == 0) continue;
            var entry_id: u64 = 0;
            if (iokit.IORegistryEntryGetRegistryEntryID(service, &entry_id) != 0) continue;

            var buf: [DeviceId.max_len]u8 = undefined;
            const text = naming.formatId(entry_id, &buf) orelse continue;
            out.id = DeviceId.init(text) catch continue;
            return true;
        }
        return false;
    }
};

test {
    std.testing.refAllDecls(@This());
}
