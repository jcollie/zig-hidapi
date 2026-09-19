// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The transport a HID device is attached by, in terms every supported
//! operating system can answer.

const std = @import("std");

/// How a device is attached.
///
/// Deliberately exhaustive and deliberately short. The tempting alternative
/// was a non-exhaustive enum numbered with Linux's `BUS_*` values from
/// `uapi/linux/input.h`, which is what this library used to expose, and it
/// does not survive portability: Windows and macOS do not report those
/// numbers and would have to invent values inside Linux's numbering, at which
/// point a caller switching on the result cannot tell an invented value from a
/// real one.
///
/// What a system did say is kept separately, on `DeviceInfo.native_bus`, so
/// nothing is lost by mapping into this.
pub const BusType = enum(u8) {
    /// The system did not say, or said something this library could not map.
    /// `DeviceInfo.native_bus` may still carry the raw value.
    unknown,
    usb,
    /// Both classic Bluetooth and Bluetooth Low Energy. The two are separate
    /// transports and separate strings on macOS and separate enumerators on
    /// Windows, but nothing in a HID conversation depends on which it is, and
    /// Linux reports one `BUS_BLUETOOTH` for both.
    bluetooth,
    i2c,
    spi,
    /// A software device with no physical transport, such as one created
    /// through Linux's `uhid`.
    virtual,
    /// A transport the system named that has no portable spelling here.
    other,

    pub fn format(self: BusType, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(switch (self) {
            .unknown => "unknown",
            .usb => "USB",
            .bluetooth => "Bluetooth",
            .i2c => "I2C",
            .spi => "SPI",
            .virtual => "virtual",
            .other => "other",
        });
    }
};

test "format spells out the acronyms" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("USB", try std.fmt.bufPrint(&buf, "{f}", .{BusType.usb}));
    try std.testing.expectEqualStrings("I2C", try std.fmt.bufPrint(&buf, "{f}", .{BusType.i2c}));
    try std.testing.expectEqualStrings("virtual", try std.fmt.bufPrint(&buf, "{f}", .{BusType.virtual}));
}

test {
    std.testing.refAllDecls(@This());
}
