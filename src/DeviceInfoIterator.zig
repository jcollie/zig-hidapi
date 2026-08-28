// SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! An iterator over the `hidraw` devices attached to the system.
//!
//! There is no enumeration ioctl, so this walks the minor numbers `0` through
//! `63` in order, opening `/dev/hidraw{minor}` and asking each one for its
//! `DeviceInfo`. Nodes that do not exist, and nodes the caller may not open,
//! are skipped, so an unprivileged process will usually see nothing at all;
//! see the udev rule in
//! [the README](https://codeberg.org/jcollie/zig-hidapi#user-content-permissions).
//! Devices numbered beyond the last minor tried are not reported.
//!
//! Each `DeviceInfo` yielded carries the `Device` that was opened to read it.
//! The caller takes ownership of that device and has to `close` it, whether or
//! not it is the one being looked for.

const DeviceInfoIterator = @This();

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.device_info_iterator);

const hidapi = @import("hidapi.zig");
const Device = @import("Device.zig");
const DeviceInfo = @import("DeviceInfo.zig");

/// The next minor number to try, i.e. the `N` in `/dev/hidrawN`.
index: linux.dev_t = 0,

/// An iterator positioned before the first device.
pub const init: DeviceInfoIterator = .{};

/// Advance to the next device that can be opened and queried, and return its
/// information.
///
/// Returns `null` once the last minor number has been tried, which also
/// happens on the very first call when nothing is attached or nothing can be
/// opened.
///
/// The `Device` inside the returned `DeviceInfo` is open, and belongs to the
/// caller from here on.
pub fn next(self: *DeviceInfoIterator, io: std.Io) !?DeviceInfo {
    if (self.index >= 64) return null;
    while (self.index < 64) {
        defer self.index += 1;
        const device = Device.open(io, self.index) catch continue;
        // An errdefer would not fire here, because failing to query the
        // device continues the scan rather than returning an error, so the
        // close has to be spelled out.
        return device.getDeviceInfo(io) catch {
            device.close(io);
            continue;
        };
    }
    return null;
}

test "enumerate" {
    const io = std.testing.io;
    var it: DeviceInfoIterator = .init;
    while (try it.next(io)) |di| {
        const d = di.device;
        defer d.close(io);

        var buf: [256]u8 = undefined;
        {
            const name = try d.getPhysicalLocation(io, &buf) orelse "(unknown)";
            log.info("name: {d} {s}", .{ d.minor, name });
        }
        {
            const name = try d.getRawName(io, &buf) orelse "(unnamed)";
            log.info("name: {d} {s}", .{ d.minor, name });
        }
        {
            const name = try d.getRawUniq(io, &buf) orelse "(unnamed)";
            log.info("uniq: {d} {s}", .{ d.minor, name });
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
