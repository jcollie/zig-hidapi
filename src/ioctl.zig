// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The parts of the kernel's `hidraw` interface this library needs: the ioctl
//! request numbers, the structures they exchange, and a thin wrapper around
//! the `ioctl` syscall itself.
//!
//! The declarations mirror `uapi/linux/hidraw.h`, and the comments on the
//! request numbers are the kernel's own text from
//! https://docs.kernel.org/hid/hidraw.html.
//!
//! This file is not exported from the root module. Three of its declarations
//! nonetheless reach `Device`'s callers: `BUS`, as the type of the bus a
//! device is attached to, `HID_MAX_DESCRIPTOR_SIZE`, as a buffer size that
//! always suffices, and `Size`, as the bound a buffer length has to fit.
//!
//! Requests that carry a caller supplied buffer are functions rather than
//! constants, because the buffer length is encoded in the request number
//! itself. They take that length as a `Size`, which is narrower than the
//! `usize` a caller usually has in hand, so the narrowing and the decision of
//! what to do about a buffer too large to name belong to the caller.

const std = @import("std");
const linux = std.os.linux;

/// The type of the length field of a request number, and so the largest
/// buffer any of the requests below can name: 14 bits on most architectures,
/// 13 bits on the ones that spend an extra bit on the direction.
///
/// Public so that a caller holding a `usize` length can narrow it, which
/// `Device` does with `std.math.cast`.
pub const Size = @FieldType(linux.IOCTL.Request, "size");

/// The bus a device is attached to, as the `BUS_*` values of
/// `uapi/linux/input.h`.
///
/// Non-exhaustive, because the kernel gains new bus types over time and may
/// report one this list does not name.
pub const BUS = enum(u32) {
    PCI = 0x01,
    ISAPNP = 0x02,
    USB = 0x03,
    HIL = 0x04,
    BLUETOOTH = 0x05,
    VIRTUAL = 0x06,
    ISA = 0x10,
    I8042 = 0x11,
    XTKBD = 0x12,
    RS232 = 0x13,
    GAMEPORT = 0x14,
    PARPORT = 0x15,
    AMIGA = 0x16,
    ADB = 0x17,
    I2C = 0x18,
    HOST = 0x19,
    GSC = 0x1A,
    ATARI = 0x1B,
    SPI = 0x1C,
    RMI = 0x1D,
    CEC = 0x1E,
    INTEL_ISHTP = 0x1F,
    AMD_SFH = 0x20,
    _,
};

/// What `HIDIOCGRAWINFO` fills in, laid out as `struct hidraw_devinfo`.
///
/// The kernel declares the vendor and product fields signed. They are the
/// same bits either way, and a VID or PID reads as an unsigned number, so they
/// are `u16` here.
pub const hidraw_devinfo = extern struct {
    bustype: BUS,
    vendor: u16,
    product: u16,

    /// A zeroed value to hand to the ioctl.
    ///
    /// Zero is not one of the `BUS_*` values, which only a non-exhaustive
    /// `BUS` can represent; a device that answers always overwrites it.
    pub const init: hidraw_devinfo = .{
        .bustype = @enumFromInt(0),
        .vendor = 0,
        .product = 0,
    };

    comptime {
        // The kernel copies this structure in and out by size, so a layout
        // that drifts from the header has to fail the build rather than
        // quietly exchange the wrong bytes.
        std.debug.assert(@sizeOf(hidraw_devinfo) == 8);
    }
};

/// The largest report descriptor the kernel will hand out, so a buffer this
/// size always fits one.
pub const HID_MAX_DESCRIPTOR_SIZE = 4096;

/// What `HIDIOCGRDESC` fills in, laid out as
/// `struct hidraw_report_descriptor`.
///
/// The buffer is a fixed `HID_MAX_DESCRIPTOR_SIZE` bytes rather than a
/// pointer, so a value of this type is over 4 KiB and is worth keeping off a
/// small stack.
pub const hidraw_report_descriptor = extern struct {
    size: u32,
    value: [HID_MAX_DESCRIPTOR_SIZE]u8,

    /// A zeroed descriptor asking for `size` bytes.
    ///
    /// `HIDIOCGRDESC` copies out only as many bytes as this says, so `size`
    /// has to be set before the call, from `HIDIOCGRDESCSIZE`.
    pub fn init(size: u32) hidraw_report_descriptor {
        return .{
            .size = size,
            .value = @splat(0),
        };
    }
};

/// This ioctl will get the size of the device’s report descriptor.
pub const HIDIOCGRDESCSIZE = linux.IOCTL.IOR('H', 0x01, u32);

/// This ioctl returns the device’s report descriptor using a
/// hidraw_report_descriptor struct. Make sure to set the size field of the
/// hidraw_report_descriptor struct to the size returned from HIDIOCGRDESCSIZE.
pub const HIDIOCGRDESC = linux.IOCTL.IOR('H', 0x02, hidraw_report_descriptor);

/// This ioctl will return a hidraw_devinfo struct containing the bus type, the
/// vendor ID (VID), and product ID (PID) of the device. The bus type can be
/// one of:
///
/// - BUS_USB
/// - BUS_HIL
/// - BUS_BLUETOOTH
/// - BUS_VIRTUAL
///
/// which are defined in uapi/linux/input.h.
pub const HIDIOCGRAWINFO = linux.IOCTL.IOR('H', 0x03, hidraw_devinfo);

// The direction bits of an ioctl request number, named from userspace's point
// of view: `read` means the kernel writes into the caller's buffer. They match
// the encoding `std.os.linux.IOCTL` uses on x86, ARM, RISC-V and the rest of
// the common architectures. MIPS, PowerPC and SPARC spend three bits on the
// direction and give the write bit a different value, so unlike `Size`, which
// follows whatever the target uses, these do not, and the requests built below
// would be wrong there.
const read = 2;
const write = 1;

/// This ioctl returns a string containing the vendor and product strings of the
/// device. The returned string is Unicode, UTF-8 encoded.
pub fn HIDIOCGRAWNAME(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x04,
        .dir = read,
        .size = len,
    };
    return @bitCast(request);
}

/// This ioctl returns a string representing the physical address of the
/// device. For USB devices, the string contains the physical path to the device
/// (the USB controller, hubs, ports, etc). For Bluetooth devices, the string
/// contains the hardware (MAC) address of the device.
pub fn HIDIOCGRAWPHYS(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x05,
        .dir = read,
        .size = len,
    };
    return @bitCast(request);
}

/// This ioctl will send a feature report to the device. Per the HID
/// specification, feature reports are always sent using the control endpoint.
/// Set the first byte of the supplied buffer to the report number. For devices
/// which do not use numbered reports, set the first byte to 0. The report data
/// begins in the second byte. Make sure to set len accordingly, to one more
/// than the length of the report (to account for the report number).
pub fn HIDIOCSFEATURE(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x06,
        .dir = read | write,
        .size = len,
    };
    return @bitCast(request);
}

/// This ioctl will request a feature report from the device using the control
/// endpoint. The first byte of the supplied buffer should be set to the report
/// number of the requested report. For devices which do not use numbered
/// reports, set the first byte to 0. The returned report buffer will contain
/// the report number in the first byte, followed by the report data read from
/// the device. For devices which do not use numbered reports, the report data
/// will begin at the first byte of the returned buffer.
pub fn HIDIOCGFEATURE(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x07,
        .dir = read | write,
        .size = len,
    };
    return @bitCast(request);
}

/// This ioctl returns the kernel's `uniq` string for the device, which usbhid
/// fills in from the device's serial number and the Bluetooth transport fills
/// in with the hardware (MAC) address. Devices that report neither leave it
/// empty.
///
/// Unlike the comments above, this one is not the kernel's own text: the
/// hidraw documentation does not cover this request. Nothing in this library
/// issues it yet.
pub fn HIDIOCGRAWUNIQ(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x08,
        .dir = read,
        .size = len,
    };
    return @bitCast(request);
}

/// This ioctl will send an input report to the device, using the control
/// endpoint. In most cases, setting an input HID report on a device is
/// meaningless and has no effect, but some devices may choose to use this to
/// set or reset an initial state of a report. The format of the buffer issued
/// with this report is identical to that of HIDIOCSFEATURE.
pub fn HIDIOCSINPUT(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x09,
        .dir = read | write,
        .size = len,
    };
    return @bitCast(request);
}

/// This ioctl will request an input report from the device using the control
/// endpoint. This is slower on most devices where a dedicated In endpoint
/// exists for regular input reports, but allows the host to request the value
/// of a specific report number. Typically, this is used to request the initial
/// states of an input report of a device, before an application listens for
/// normal reports via the regular device read() interface. The format of the
/// buffer issued with this report is identical to that of HIDIOCGFEATURE.
pub fn HIDIOCGINPUT(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0A,
        .dir = read | write,
        .size = len,
    };
    return @bitCast(request);
}

/// This ioctl will send an output report to the device, using the control
/// endpoint. This is slower on most devices where a dedicated Out endpoint
/// exists for regular output reports, but is added for completeness. Typically,
/// this is used to set the initial states of an output report of a device,
/// before an application sends updates via the regular device write()
/// interface. The format of the buffer issued with this report is identical to
/// that of HIDIOCSFEATURE.
pub fn HIDIOCSOUTPUT(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0B,
        .dir = read | write,
        .size = len,
    };
    return @bitCast(request);
}

/// This ioctl will request an output report from the device using the control
/// endpoint. Typically, this is used to retrieve the initial state of an
/// output report of a device, before an application updates it as necessary
/// either via a HIDIOCSOUTPUT request, or the regular device write() interface.
/// The format of the buffer issued with this report is identical to that of
/// HIDIOCGFEATURE.
pub fn HIDIOCGOUTPUT(len: Size) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0C,
        .dir = read | write,
        .size = len,
    };
    return @bitCast(request);
}

/// The outcome of an ioctl: what the syscall returned, or why it refused.
pub const IOCtlResult = union(enum) {
    /// The syscall's return value. Most of these requests return zero, but
    /// the ones that copy a string out return the number of bytes copied,
    /// including the terminator.
    success: usize,
    /// The `errno` the syscall set.
    failure: linux.E,
};

/// Issue `request` on `fd` with `arg`, dispatched through `io`.
///
/// A failing syscall is reported as `.failure` rather than an error, leaving
/// each caller to decide which `errno` values matter to it. The error union
/// only covers a failure to dispatch the call through `io` in the first place.
pub fn ioctl(io: std.Io, fd: linux.fd_t, request: u32, arg: usize) !IOCtlResult {
    var future = try io.concurrent(_ioctl, .{ fd, request, arg });
    defer _ = future.cancel(io);
    const rc = future.await(io);
    switch (linux.errno(rc)) {
        .SUCCESS => return .{ .success = rc },
        else => |e| return .{ .failure = e },
    }
}

/// The blocking half of `ioctl`, the part that `io` runs.
fn _ioctl(fd: linux.fd_t, request: u32, arg: usize) usize {
    return linux.ioctl(fd, request, arg);
}

test {
    std.testing.refAllDecls(@This());
}
