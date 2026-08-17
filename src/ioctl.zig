// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// See https://docs.kernel.org/hid/hidraw.html

const std = @import("std");
const linux = std.os.linux;

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

pub const hidraw_devinfo = extern struct {
    bustype: BUS,
    vendor: u16,
    product: u16,

    pub const init: hidraw_devinfo = .{ 0, 0, 0 };

    comptime {
        std.debug.assert(@sizeOf(hidraw_devinfo) == 8);
    }
};

pub const HID_MAX_DESCRIPTOR_SIZE = 4096;

pub const hidraw_report_descriptor = extern struct {
    size: u32,
    value: [HID_MAX_DESCRIPTOR_SIZE]u8,

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

const read = 2;
const write = 1;

/// This ioctl returns a string containing the vendor and product strings of the
/// device. The returned string is Unicode, UTF-8 encoded.
pub fn HIDIOCGRAWNAME(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x04,
        .dir = read,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

/// This ioctl returns a string representing the physical address of the
/// device. For USB devices, the string contains the physical path to the device
/// (the USB controller, hubs, ports, etc). For Bluetooth devices, the string
/// contains the hardware (MAC) address of the device.
pub fn HIDIOCGRAWPHYS(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x05,
        .dir = read,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

/// This ioctl will send a feature report to the device. Per the HID
/// specification, feature reports are always sent using the control endpoint.
/// Set the first byte of the supplied buffer to the report number. For devices
/// which do not use numbered reports, set the first byte to 0. The report data
/// begins in the second byte. Make sure to set len accordingly, to one more
/// than the length of the report (to account for the report number).
pub fn HIDIOCSFEATURE(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x06,
        .dir = read | write,
        .size = @intCast(len),
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
pub fn HIDIOCGFEATURE(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x07,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCGRAWUNIQ(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x08,
        .dir = read,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

/// This ioctl will send an input report to the device, using the control
/// endpoint. In most cases, setting an input HID report on a device is
/// meaningless and has no effect, but some devices may choose to use this to
/// set or reset an initial state of a report. The format of the buffer issued
/// with this report is identical to that of HIDIOCSFEATURE.
pub fn HIDIOCSINPUT(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x09,
        .dir = read | write,
        .size = @intCast(len),
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
pub fn HIDIOCGINPUT(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0A,
        .dir = read | write,
        .size = @intCast(len),
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
pub fn HIDIOCSOUTPUT(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0B,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

/// This ioctl will request an output report from the device using the control
/// endpoint. Typically, this is used to retrieve the initial state of an
/// output report of a device, before an application updates it as necessary
/// either via a HIDIOCSOUTPUT request, or the regular device write() interface.
/// The format of the buffer issued with this report is identical to that of
/// HIDIOCGFEATURE.
pub fn HIDIOCGOUTPUT(len: usize) u32 {
    const request: linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0C,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub const IOCtlResult = union(enum) {
    success: usize,
    failure: linux.E,
};

pub fn ioctl(io: std.Io, fd: linux.fd_t, request: u32, arg: usize) !IOCtlResult {
    var future = try io.concurrent(_ioctl, .{ fd, request, arg });
    defer _ = future.cancel(io);
    const rc = future.await(io);
    switch (linux.errno(rc)) {
        .SUCCESS => return .{ .success = rc },
        else => |e| return .{ .failure = e },
    }
}

fn _ioctl(fd: linux.fd_t, request: u32, arg: usize) usize {
    return linux.ioctl(fd, request, arg);
}
