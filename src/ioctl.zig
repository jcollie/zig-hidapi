const std = @import("std");

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
};

comptime {
    std.debug.assert(@sizeOf(hidraw_devinfo) == 8);
}

pub const HID_MAX_DESCRIPTOR_SIZE = 4096;

pub const hidraw_report_descriptor = extern struct {
    size: u32,
    value: [HID_MAX_DESCRIPTOR_SIZE]u8,

    pub fn init(size: c_int) hidraw_report_descriptor {
        return .{
            .size = @intCast(size),
            .value = std.mem.zeroes([HID_MAX_DESCRIPTOR_SIZE]u8),
        };
    }
};

pub const HIDIOCGRDESCSIZE = std.os.linux.IOCTL.IOR('H', 0x01, c_int);
pub const HIDIOCGRDESC = std.os.linux.IOCTL.IOR('H', 0x02, hidraw_report_descriptor);
pub const HIDIOCGRAWINFO = std.os.linux.IOCTL.IOR('H', 0x03, hidraw_devinfo);

const read = 2;
const write = 1;

pub fn HIDIOCGRAWNAME(len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x04,
        .dir = read,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCGRAWPHYS(comptime len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x05,
        .dir = read,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCSFEATURE(len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x06,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCGFEATURE(len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x07,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCGRAWUNIQ(comptime len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x08,
        .dir = read,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCSINPUT(comptime len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x09,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCGINPUT(comptime len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0A,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCSOUTPUT(comptime len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0B,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}

pub fn HIDIOCGOUTPUT(comptime len: usize) u32 {
    const request: std.os.linux.IOCTL.Request = .{
        .io_type = 'H',
        .nr = 0x0C,
        .dir = read | write,
        .size = @intCast(len),
    };
    return @bitCast(request);
}
