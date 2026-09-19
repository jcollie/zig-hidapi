// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! IOKit's HID Manager, declared rather than imported.
//!
//! This is the only way to talk to a HID device on macOS. There is no ioctl
//! interface and no device node; a device is an `IOHIDDeviceRef` obtained from
//! the I/O Registry, and input reports arrive on a callback rather than being
//! read.
//!
//! **None of the `kIOHID*Key` names below is a symbol.** They are `#define`s
//! of string literals in `IOHIDDeviceKeys.h`, so they are plain Zig string
//! constants here. Declaring one `extern const` compiles and then fails to
//! link, on the platform where that is most expensive to discover. The same
//! goes for `kIOServicePlane`.
//!
//! `kIOMasterPortDefault` *is* a data symbol, and is deliberately not declared:
//! its value is `MACH_PORT_NULL`, it was renamed `kIOMainPortDefault` in macOS
//! 12, and passing a literal `0` works on every version. The C hidapi does the
//! same.

const std = @import("std");
const c = std.c;

const cf = @import("cf.zig");

pub const mach_port_t = c.mach_port_t;
pub const kern_return_t = c.kern_return_t;
pub const io_object_t = mach_port_t;
pub const io_service_t = mach_port_t;
pub const io_registry_entry_t = mach_port_t;
pub const io_string_t = [512]u8;

pub const IOReturn = kern_return_t;
pub const IOOptionBits = u32;

pub const kIOReturnSuccess: IOReturn = 0;

/// `MACH_PORT_NULL`, which is what to pass where a master port is wanted.
pub const null_port: mach_port_t = 0;

pub const kIOServicePlane = "IOService";

pub const IOHIDDeviceRef = ?*anyopaque;
pub const IOHIDManagerRef = ?*anyopaque;

pub const IOHIDReportType = enum(c_int) {
    input = 0,
    output = 1,
    feature = 2,
    _,
};

pub const kIOHIDOptionsTypeNone: IOOptionBits = 0x00;

/// Open the device exclusively, which stops the system and every other
/// program receiving events from it for as long as it is held.
pub const kIOHIDOptionsTypeSeizeDevice: IOOptionBits = 0x01;

pub const IOHIDCallback = *const fn (
    context: ?*anyopaque,
    result: IOReturn,
    sender: ?*anyopaque,
) callconv(.c) void;

pub const IOHIDReportCallback = *const fn (
    context: ?*anyopaque,
    result: IOReturn,
    sender: ?*anyopaque,
    report_type: IOHIDReportType,
    report_id: u32,
    report: [*]u8,
    report_length: cf.CFIndex,
) callconv(.c) void;

// ---- property keys: string constants, not symbols -------------------------

pub const kIOHIDTransportKey = "Transport";
pub const kIOHIDVendorIDKey = "VendorID";
pub const kIOHIDProductIDKey = "ProductID";
pub const kIOHIDVersionNumberKey = "VersionNumber";
pub const kIOHIDManufacturerKey = "Manufacturer";
pub const kIOHIDProductKey = "Product";
pub const kIOHIDSerialNumberKey = "SerialNumber";
pub const kIOHIDLocationIDKey = "LocationID";
pub const kIOHIDPrimaryUsageKey = "PrimaryUsage";
pub const kIOHIDPrimaryUsagePageKey = "PrimaryUsagePage";
pub const kIOHIDMaxInputReportSizeKey = "MaxInputReportSize";
pub const kIOHIDMaxOutputReportSizeKey = "MaxOutputReportSize";
pub const kIOHIDMaxFeatureReportSizeKey = "MaxFeatureReportSize";

/// Microseconds a synchronous request may take before IOKit abandons it.
///
/// Worth setting, because `IOHIDDeviceGetReport` and `SetReport` are
/// synchronous calls that `Io` cannot cancel -- see the note in `darwin.zig`
/// -- so without it a wedged device holds a task forever.
pub const kIOHIDRequestTimeoutKey = "RequestTimeout";

/// The raw HID report descriptor, as a `CFData`.
///
/// Apple documents this key only for DriverKit, not for the user-space HID
/// Manager, but `IOHIDDevice` publishes it and the C hidapi has relied on it
/// for years. It is the one thing macOS gives that Windows does not.
pub const kIOHIDReportDescriptorKey = "ReportDescriptor";

// ---- transport values -----------------------------------------------------

pub const kIOHIDTransportUSBValue = "USB";
pub const kIOHIDTransportBluetoothValue = "Bluetooth";
pub const kIOHIDTransportBluetoothLowEnergyValue = "BluetoothLowEnergy";
pub const kIOHIDTransportI2CValue = "I2C";
pub const kIOHIDTransportSPIValue = "SPI";

// ---- functions ------------------------------------------------------------

pub extern fn IOObjectRelease(object: io_object_t) callconv(.c) kern_return_t;
pub extern fn IORegistryEntryGetRegistryEntryID(
    entry: io_registry_entry_t,
    entryID: *u64,
) callconv(.c) kern_return_t;
pub extern fn IORegistryEntryIDMatching(entryID: u64) callconv(.c) cf.CFDictionaryRef;
pub extern fn IOServiceGetMatchingService(
    masterPort: mach_port_t,
    matching: cf.CFDictionaryRef,
) callconv(.c) io_service_t;
pub extern fn IORegistryEntryCreateCFProperty(
    entry: io_registry_entry_t,
    key: cf.CFStringRef,
    allocator: cf.CFAllocatorRef,
    options: IOOptionBits,
) callconv(.c) cf.CFTypeRef;

pub extern fn IOHIDManagerCreate(
    allocator: cf.CFAllocatorRef,
    options: IOOptionBits,
) callconv(.c) IOHIDManagerRef;
pub extern fn IOHIDManagerSetDeviceMatching(
    manager: IOHIDManagerRef,
    matching: cf.CFDictionaryRef,
) callconv(.c) void;
pub extern fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) callconv(.c) cf.CFSetRef;

pub extern fn IOHIDDeviceCreate(
    allocator: cf.CFAllocatorRef,
    service: io_service_t,
) callconv(.c) IOHIDDeviceRef;
pub extern fn IOHIDDeviceGetService(device: IOHIDDeviceRef) callconv(.c) io_service_t;
pub extern fn IOHIDDeviceOpen(device: IOHIDDeviceRef, options: IOOptionBits) callconv(.c) IOReturn;
pub extern fn IOHIDDeviceClose(device: IOHIDDeviceRef, options: IOOptionBits) callconv(.c) IOReturn;
pub extern fn IOHIDDeviceGetProperty(
    device: IOHIDDeviceRef,
    key: cf.CFStringRef,
) callconv(.c) cf.CFTypeRef;
pub extern fn IOHIDDeviceSetProperty(
    device: IOHIDDeviceRef,
    key: cf.CFStringRef,
    value: cf.CFTypeRef,
) callconv(.c) cf.Boolean;
pub extern fn IOHIDDeviceScheduleWithRunLoop(
    device: IOHIDDeviceRef,
    rl: cf.CFRunLoopRef,
    mode: cf.CFStringRef,
) callconv(.c) void;
pub extern fn IOHIDDeviceUnscheduleFromRunLoop(
    device: IOHIDDeviceRef,
    rl: cf.CFRunLoopRef,
    mode: cf.CFStringRef,
) callconv(.c) void;
pub extern fn IOHIDDeviceRegisterInputReportCallback(
    device: IOHIDDeviceRef,
    report: [*]u8,
    reportLength: cf.CFIndex,
    callback: ?IOHIDReportCallback,
    context: ?*anyopaque,
) callconv(.c) void;
pub extern fn IOHIDDeviceRegisterRemovalCallback(
    device: IOHIDDeviceRef,
    callback: ?IOHIDCallback,
    context: ?*anyopaque,
) callconv(.c) void;
pub extern fn IOHIDDeviceSetReport(
    device: IOHIDDeviceRef,
    reportType: IOHIDReportType,
    reportID: cf.CFIndex,
    report: [*]const u8,
    reportLength: cf.CFIndex,
) callconv(.c) IOReturn;
pub extern fn IOHIDDeviceGetReport(
    device: IOHIDDeviceRef,
    reportType: IOHIDReportType,
    reportID: cf.CFIndex,
    report: [*]u8,
    pReportLength: *cf.CFIndex,
) callconv(.c) IOReturn;

test {
    std.testing.refAllDecls(@This());
}
