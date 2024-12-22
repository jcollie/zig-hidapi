const std = @import("std");

const hidapi = @cImport({
    @cInclude("hidapi/hidapi.h");
});

const Errors = error{
    HidApiInitError,
    HidApiExitError,
};

const MAX_REPORT_DESCRIPTOR_SIZE = hidapi.HID_API_MAX_REPORT_DESCRIPTOR_SIZE;

const HidBusType = enum(hidapi.hid_bus_type) {
    UNKNOWN = hidapi.HID_API_BUS_UNKNOWN,
    USB = hidapi.HID_API_BUS_USB,
    BLUETOOTH = hidapi.HID_API_BUS_BLUETOOTH,
    I2C = hidapi.HID_API_BUS_I2C,
    SPI = hidapi.HID_API_BUS_SPI,
    _,
};

pub const HidApiInitErrors = error{
    HidApiInitError,
};

pub fn init() HidApiInitErrors!void {
    const ret = hidapi.hid_init();
    if (ret != 0) return error.HidApiInitError;
}

pub const HidApiExitErrors = error{
    HidApiExitError,
};

pub fn exit() HidApiExitErrors!void {
    const ret = hidapi.hid_exit();
    if (ret != 0) return error.HidApiExitError;
}

pub fn getError(alloc: std.mem.Allocator) ![]const u8 {
    const err = try from_wchar_alloc(alloc, hidapi.hid_error(null));
    if (err) |e| return e;
    return "";
}

const DeviceInfo = struct {
    vendor_id: c_ushort,
    product_id: c_ushort,
    path: []u8,
    serial_number: ?[]u8,
    release_number: c_ushort,
    manufacturer: ?[]u8,
    product: ?[]u8,
    usage_page: c_ushort,
    usage: c_ushort,
    interface_number: c_int,
    bus_type: HidBusType,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, hid_device_info: [*c]hidapi.hid_device_info) !DeviceInfo {
        return .{
            .vendor_id = hid_device_info.*.vendor_id,
            .product_id = hid_device_info.*.product_id,
            .release_number = hid_device_info.*.release_number,
            .path = try alloc.dupe(u8, std.mem.span(hid_device_info.*.path)),
            .serial_number = try from_wchar_alloc(alloc, hid_device_info.*.serial_number),
            .manufacturer = try from_wchar_alloc(alloc, hid_device_info.*.manufacturer_string),
            .product = try from_wchar_alloc(alloc, hid_device_info.*.product_string),
            .usage_page = hid_device_info.*.usage_page,
            .usage = hid_device_info.*.usage,
            .interface_number = hid_device_info.*.interface_number,
            .bus_type = @enumFromInt(hid_device_info.*.bus_type),
        };
    }

    // pub fn open(self: Self) !Device {
    //     const d = Device{
    //         .device = hidapi.hid_open_path(self.path),
    //     };
    //     if (d.device) return d;
    //     const err = hidapi.hid_error(null);
    //     d.err = try from_wchar_alloc(err, &d.err);
    //     return d;
    // }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{x:0>4} {x:0>4} {s} '{?s}'\n", .{ self.vendor_id, self.product_id, self.path, self.serial_number });
        try writer.print("Manufacturer: {?s}\n", .{self.manufacturer});
        try writer.print("Product:      {?s}\n", .{self.product});
        try writer.print("Release:      0x{x}\n", .{self.release_number});
        try writer.print("Interface:    0x{x}\n", .{self.interface_number});
        try writer.print("Usage (page): 0x{x} (0x{x})\n", .{ self.usage, self.usage_page });
        try writer.print("Bus type:     {} ({})\n", .{
            self.bus_type,
            @intFromEnum(self.bus_type),
        });
    }

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.serial_number);
        alloc.free(self.manufacturer);
        alloc.free(self.product);
    }
};

pub const DeviceInfoIterator = struct {
    start: ?*hidapi.hid_device_info,
    current: ?*hidapi.hid_device_info,

    pub fn next(self: *DeviceInfoIterator, alloc: std.mem.Allocator) !?DeviceInfo {
        if (self.current) |current| {
            self.current = current.next;
            return try DeviceInfo.init(alloc, current);
        }
        return null;
    }

    pub fn deinit(self: *DeviceInfoIterator) void {
        if (self.start) |start| hidapi.hid_free_enumeration(start);
    }
};

pub fn enumerate(vendor_id: c_ushort, product_id_: ?c_ushort) !DeviceInfoIterator {
    const product_id = product_id_ orelse 0x0000;
    const device_info: ?*hidapi.hid_device_info = hidapi.hid_enumerate(vendor_id, product_id);

    return .{
        .start = device_info,
        .current = device_info,
    };
}

pub fn version() struct { major: c_int, minor: c_int, patch: c_int } {
    if (hidapi.hid_version()) |v| {
        return .{
            .major = v.*.major,
            .minor = v.*.minor,
            .patch = v.*.patch,
        };
    }
    return .{ .major = 0, .minor = 0, .patch = 0 };
}

test "version-1" {
    const v = version();
    try std.testing.expectEqual(@as(i32, 0), v.major);
    try std.testing.expectEqual(@as(i32, 14), v.minor);
    try std.testing.expectEqual(@as(i32, 0), v.patch);
}

pub fn version_str() []const u8 {
    return std.mem.span(hidapi.hid_version_str());
}

test "version-2" {
    const v = version_str();
    try std.testing.expectEqualStrings("0.14.0", v);
}

pub const Device = struct {
    device: *hidapi.hid_device,

    const Self = @This();

    pub fn open(vendor_id: c_ushort, product_id: c_ushort, serial_number: ?[]const u8) !Device {
        var buffer: [128]hidapi.wchar_t = undefined;
        const device = hidapi.hid_open(
            vendor_id,
            product_id,
            if (serial_number) |s| try to_wchar(s, &buffer) else null,
        );
        if (device) |d| return .{ .device = d };
        return error.HIDApiError;
    }

    pub fn openPath(path: [:0]const u8) !Device {
        const device = hidapi.hid_open_path(path.ptr);
        if (device) |d| return .{ .device = d };
        return error.HIDApiError;
    }

    pub fn close(self: Self) void {
        hidapi.hid_close(self.device);
    }

    pub fn getVendorID(self: Self) !c_ushort {
        const di = hidapi.hid_get_device_info(self.device);
        return di.*.vendor_id;
    }

    pub fn getProductID(self: Self) !c_ushort {
        const di = hidapi.hid_get_device_info(self.device);
        return di.*.product_id;
    }

    pub fn getError(self: Self, alloc: std.mem.Allocator) ![]const u8 {
        const err = try from_wchar_alloc(alloc, hidapi.hid_error(self.device));
        if (err) |e| return e;
        return "";
    }

    /// Send a Feature report to the device.
    ///
    /// Feature reports are sent over the Control endpoint as a Set_Report
    /// transfer.  The first byte of `data` must contain the Report ID. For
    /// devices which only support a single report, this must be set to 0x0.
    /// The remaining bytes contain the report data. Since the Report ID is
    /// mandatory, calls to sendFeatureReport() will always contain one more
    /// byte than the report contains. For example, if a hid report is 16 bytes
    /// long, 17 bytes must be passed to hid_send_feature_report(): the Report
    /// ID (or 0x0, for devices which do not use numbered reports), followed by
    /// the report data (16 bytes). In this example, the length passed in would
    /// be 17.
    pub fn sendFeatureReport(self: Self, data: []const u8) !usize {
        const result = hidapi.hid_send_feature_report(self.device, data.ptr, data.len);
        if (result < 0) return error.HIDApiError;
        return @intCast(result);
    }

    /// Get a feature report from a HID device.
    ///
    /// Set the first byte of `data` to the Report ID of the report to be read.
    /// Make sure to allow space for this extra byte in `data`. Upon return, the
    /// first byte will still contain the Report ID, and the report data will
    /// start in data[1].
    pub fn getFeatureReport(self: Self, buffer: []u8) ![]const u8 {
        const result = hidapi.hid_get_feature_report(self.device, buffer.ptr, buffer.len);
        if (result < 0) return error.HIDAPiError;
        return buffer[0..@intCast(result)];
    }

    /// Get a input report from a HID device.
    ///
    /// Set the first byte of `data` to the Report ID of the report to be read.
    /// Make sure to allow space for this extra byte in `data`. Upon return, the
    /// first byte will still contain the Report ID, and the report data will
    /// start in `data[1]`.
    pub fn getInputReport(self: @This(), buffer: []u8) ![]const u8 {
        const result = hidapi.hid_get_input_report(self.device, buffer.ptr, buffer.len);
        if (result < 1) return error.HIDApiError;
        return buffer[0..@intCast(result)];
    }

    /// Set the device handle to be non-blocking.
    ///
    /// In non-blocking mode calls to read() will return immediately with a
    /// null if there is no data to be read. In blocking mode, read() will
    /// wait (block) until there is data to read before returning.
    ///
    /// Nonblocking can be turned on and off at any time.
    pub fn setNonblocking(self: @This(), nonblocking: bool) !void {
        const result = hidapi.hid_set_nonblocking(self.device, if (nonblocking) 1 else 0);
        if (result < 0) return error.HIDApiError;
    }

    /// Write an Output report to a HID device.
    ///
    /// The first byte of `data` must contain the Report ID. For
    /// devices which only support a single report, this must be set
    /// to 0x0. The remaining bytes contain the report data. Since
    /// the Report ID is mandatory, calls to `write()` will always
    /// contain one more byte than the report contains. For example,
    /// if a HID report is 16 bytes long, 17 bytes must be passed to
    /// `write()`, the Report ID (or 0x0, for devices with a
    /// single report), followed by the report data (16 bytes).
    ///
    /// write() will send the data on the first OUT endpoint, if
    /// one exists. If it does not, it will send the data through
    /// the Control Endpoint (Endpoint 0).
    pub fn write(self: @This(), data: []const u8) !usize {
        const result = hidapi.hid_write(self.device, data.ptr, data.len);
        if (result < 0) return error.HIDApiError;
        return @intCast(result);
    }

    /// Read an Input report from a HID device with timeout.
    ///
    /// Input reports are returned to the host through the INTERRUPT IN endpoint.
    /// The first byte will contain the Report number if the device uses numbered
    /// reports.
    pub fn readTimeout(self: @This(), buffer: []u8, milliseconds: c_int) !?[]const u8 {
        const result = hidapi.hid_read_timeout(self.device, buffer.ptr, buffer.len, milliseconds);
        if (result < 0) return error.HIDApiError;
        if (result == 0) return null;
        return buffer[0..result];
    }

    /// Read an Input report from a HID device.
    ///
    /// Input reports are returned to the host through the INTERRUPT IN endpoint.
    /// The first byte will contain the Report number if the device uses numbered
    /// reports.
    pub fn read(self: @This(), buffer: []u8) !?[]const u8 {
        const result = hidapi.hid_read(self.device, buffer.ptr, buffer.len);
        if (result < 0) return error.HIDApiError;
        if (result == 0) return null;
        return buffer[0..@intCast(result)];
    }

    /// Get The Manufacturer String from a HID device.
    pub fn getManufacturerString(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
        var buffer: [128]hidapi.wchar_t = undefined;
        const result = hidapi.hid_get_manufacturer_string(self.device, &buffer, buffer.len);
        if (result < 0) return error.HIDApiError;
        return (try from_wchar_alloc(alloc, &buffer)) orelse return error.HIDApiError;
    }

    /// Get The Product String from a HID device.
    pub fn getProductString(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
        var buffer: [128]hidapi.wchar_t = undefined;
        const result = hidapi.hid_get_product_string(self.device, &buffer, buffer.len);
        if (result < 0) return error.HIDApiError;
        return (try from_wchar_alloc(alloc, &buffer)) orelse return error.HIDApiError;
    }

    /// Get The Serial Number String from a HID device.
    pub fn getSerialNumberString(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
        var buffer: [128]hidapi.wchar_t = undefined;
        const result = hidapi.hid_get_serial_number_string(self.device, &buffer, buffer.len);
        if (result < 0) return error.HIDApiError;
        return try from_wchar_alloc(alloc, &buffer);
    }

    /// Get a string from a HID device, based on its string index.
    pub fn getIndexedString(self: @This(), alloc: std.mem.Allocator, string_index: c_int) ![]const u8 {
        var buffer: [128]hidapi.wchar_t = undefined;
        const result = hidapi.hid_get_indexed_string(self.device, string_index, &buffer, buffer.len);
        if (result < 0) return error.HIDApiError;
        return try from_wchar_alloc(alloc, &buffer);
    }

    /// Get a report descriptor from a HID device.
    pub fn getReportDescriptor(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
        var buffer: [MAX_REPORT_DESCRIPTOR_SIZE]u8 = undefined;
        const result = hidapi.hid_get_report_descriptor(self.device, &buffer, buffer.len);
        if (result < 0) return error.HIDApiError;
        return try alloc.dupe(u8, buffer[0..@intCast(result)]);
    }

    pub fn getDeviceInfo(self: @This(), alloc: std.mem.Allocator) !DeviceInfo {
        if (hidapi.hid_get_device_info(self.device)) |hid_device_info| {
            return DeviceInfo.init(alloc, hid_device_info);
        }
        return error.HIDApiError;
    }
};

fn from_wchar_alloc(alloc: std.mem.Allocator, wide_string: [*c]const hidapi.wchar_t) !?[]u8 {
    if (wide_string == null) return null;
    var output = std.ArrayList(u8).init(alloc);
    var writer = output.writer();
    var index: usize = 0;
    while (wide_string[index] != 0) : (index += 1) {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(@intCast(wide_string[index]), &buf);
        try writer.writeAll(buf[0..len]);
    }
    return try output.toOwnedSlice();
}

fn to_wchar_alloc(alloc: std.mem.Allocator, string: []const u8) ![*c]hidapi.wchar_t {
    var list = std.ArrayList(hidapi.wchar_t).init(alloc);
    errdefer list.deinit();
    var iter = (try std.unicode.Utf8View.init(string)).iterator();
    while (iter.nextCodepoint()) |codepoint| {
        try list.append(@intCast(codepoint));
    }
    return try list.toOwnedSliceSentinel(0);
}

fn to_wchar(string: []const u8, buffer: []hidapi.wchar_t) ![*c]hidapi.wchar_t {
    var iter = (try std.unicode.Utf8View.init(string)).iterator();
    var index: usize = 0;
    while (iter.nextCodepoint()) |codepoint| : (index += 1) {
        buffer[index] = @intCast(codepoint);
    }
    buffer[index] = 0;
    return buffer.ptr;
}
