// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What can go wrong, named once for every backend.
//!
//! These sets are explicit rather than inferred. An inferred set changes shape
//! when a backend is added, which for a library means a caller's `switch` can
//! stop compiling because someone else's operating system grew a failure mode;
//! it also means the published reference lists whatever set the machine that
//! built the documentation happened to produce. Naming them fixes both.
//!
//! The one deliberate catch-all is `DeviceRefused`. Enumerating every `errno`,
//! `NTSTATUS` and `IOReturn` into the public sets would make them differ per
//! target and force callers to handle failures that cannot happen where they
//! are, so the native code is logged at warning level and the error says what
//! happened rather than which number said so.

const std = @import("std");

/// The failures any call that touches a device can produce.
pub const DeviceError = error{
    /// The process may not talk to this device. On Linux and FreeBSD the
    /// device node is root-only until a udev or devd rule says otherwise; on
    /// Windows the system holds keyboards and pointing devices open
    /// exclusively; on macOS the process has not been granted Input
    /// Monitoring. The README has the fix for each.
    AccessDenied,

    /// Nothing answers to that `DeviceId`. Either it was never valid on this
    /// system, or it names a device that was gone before the call. Enumerate
    /// again.
    DeviceNotFound,

    /// The device was there when the call began and is not now.
    ///
    /// Separate from `DeviceNotFound` because the answers differ: this one
    /// means stop, that one means look again. It is the expected end of a
    /// `read` loop over a device someone unplugs, which used to be
    /// indistinguishable from a malformed report.
    DeviceDisconnected,

    /// The operating system or the device rejected the request -- a report ID
    /// it does not know, a transfer the transport does not carry, a report the
    /// wrong length for it. The underlying code is logged at warning level
    /// before this is returned.
    DeviceRefused,

    /// A resource belonging to the operating system ran out: file
    /// descriptors, handles, kernel memory. Distinct from the caller's own
    /// allocator failing, which this library never does, because it does not
    /// allocate.
    SystemResources,
};

/// `Device.open`.
///
/// `ConcurrentError` is here on every target, not only on macOS. Only macOS
/// can produce it -- a device there owns a task for its whole life, so an `Io`
/// with a bounded `concurrent_limit` can refuse to open one -- but a set that
/// changes shape per target is the thing these declarations exist to avoid.
///
/// `BufferTooSmall` means `OpenOptions.input_queue` cannot hold a single input
/// report from this device.
pub const OpenError = DeviceError || std.Io.Cancelable || std.Io.ConcurrentError ||
    error{ BufferTooSmall, DeviceIdTooLong };

/// `Enumerator.init` and `Enumerator.next`.
///
/// `BufferTooSmall` means the scratch buffer could not hold this system's
/// device list; `Enumerator.recommended_scratch` is sized so that it does not
/// happen in practice.
pub const EnumerateError = DeviceError || std.Io.Cancelable || std.Io.ConcurrentError ||
    error{BufferTooSmall};

/// `Device.read` and `Device.readTimeout`.
///
/// There is no `WouldBlock`: a non-blocking read is `readTimeout` with a zero
/// duration, and it reports having found nothing by returning `null`, which is
/// also what a real timeout returns. A zero-length input report is a legal
/// thing for a device to send, so the two cases cannot share a representation.
pub const ReadError = DeviceError || std.Io.Cancelable || error{BufferTooSmall};

/// `Device.write`.
pub const WriteError = DeviceError || std.Io.Cancelable || error{ReportTooLarge};

/// `Device.getFeatureReport`, `sendFeatureReport` and `getInputReport`.
pub const ReportError = DeviceError || std.Io.Cancelable ||
    error{ ReportTooLarge, BufferTooSmall };

/// `Device.getReportDescriptor` and `getReportDescriptorLen`.
pub const DescriptorError = DeviceError || std.Io.Cancelable || error{
    BufferTooSmall,

    /// This backend cannot produce a HID report descriptor.
    ///
    /// Windows always: the HID class driver keeps only its own parsed form of
    /// the descriptor and does not serve the original bytes to user mode.
    /// macOS for the occasional device that publishes no descriptor property.
    Unsupported,
};

/// Every error any call in this library can return, for a caller that wants
/// one `catch` for the lot.
pub const AnyError = OpenError || EnumerateError || ReadError || WriteError ||
    ReportError || DescriptorError;

test "the per-operation sets are all subsets of AnyError" {
    // If this stops compiling, a set above gained a member that `AnyError`
    // does not name, and a caller switching exhaustively on `AnyError` would
    // silently stop seeing it.
    inline for (.{ OpenError, EnumerateError, ReadError, WriteError, ReportError, DescriptorError }) |Set| {
        inline for (@typeInfo(Set).error_set.?) |e| {
            // Coercing rather than merely naming it is what makes this a
            // check: an error `AnyError` does not hold fails to coerce.
            const member: AnyError = @field(anyerror, e.name);
            _ = member catch {};
        }
    }
}

test "DeviceNotFound and DeviceDisconnected are distinct" {
    // The whole reason both exist. A caller reading in a loop stops on one and
    // re-enumerates on the other, so collapsing them would be a real loss.
    try std.testing.expect(error.DeviceNotFound != error.DeviceDisconnected);
}

test {
    std.testing.refAllDecls(@This());
}
