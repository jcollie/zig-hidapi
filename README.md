<!--
SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-hidapi

A pure-Zig library for talking to USB and Bluetooth HID devices on Linux
through the kernel's [hidraw](https://docs.kernel.org/hid/hidraw.html)
interface.

Unlike bindings to the C [hidapi](https://github.com/libusb/hidapi) library,
this package has no C dependency at all. It issues the `HIDIOC*` ioctls
directly against `/dev/hidraw*` and is built on Zig 0.16's `std.Io` interface,
so every blocking operation is dispatched through the caller's I/O
implementation rather than blocking a thread outright.

## Requirements

- Zig 0.16
- Linux with the `hidraw` driver (`CONFIG_HIDRAW`), i.e. `/dev/hidraw*` present

Only Linux is supported. There is no Windows, macOS, or BSD backend, and none
is planned in the current design.

## Installation

Fetch the package into your `build.zig.zon`:

```sh
zig fetch --save git+https://codeberg.org/jcollie/zig-hidapi.git
```

Then wire the module up in `build.zig`:

```zig
const hidapi = b.dependency("hidapi", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("hidapi", hidapi.module("hidapi"));
```

## Usage

Every call takes a `std.Io` as its first argument. Declaring `main` with a
`std.process.Init` parameter is the easiest way to get one: the runtime builds
an `Io` implementation appropriate for the target and hands it over as
`init.io`. Constructing one yourself (`std.Io.Threaded`, `std.Io.Uring`) works
just as well, and is what you need when the caller is a library rather than
`main`.

### Enumerating devices

```zig
const std = @import("std");
const hidapi = @import("hidapi");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var it: hidapi.DeviceInfoIterator = .init;

    while (try it.next(io)) |info| {
        defer info.device.close(io);

        const name = try info.device.getRawName(io, &buf);
        std.debug.print("{x:0>4}:{x:0>4} [{t}] {s}\n", .{
            info.vendor,
            info.product,
            info.bustype,
            name,
        });
    }
}
```

The iterator walks `/dev/hidraw0` through `/dev/hidraw63`, silently skipping
any node that does not exist or cannot be opened. Devices it yields are already
open; the caller owns them and is responsible for closing them.

### Opening a device directly

```zig
const device = try hidapi.Device.open(io, 0); // /dev/hidraw0
defer device.close(io);
```

`open` reports `error.HIDDeviceDoesNotExist` when the node is missing and
`error.HIDDeviceNoAccess` when permissions deny it.

### Reading and writing reports

```zig
// Write an output report. The first byte is the report ID; use 0 for
// devices that do not use numbered reports.
var out: [17]u8 = @splat(0);
out[0] = 0x00;
out[1] = 0x42;
_ = try device.write(io, &out);

// Read an input report.
var in: [64]u8 = undefined;
const report = try device.read(io, &in);
std.debug.print("read {d} bytes\n", .{report.len});
```

### Feature reports

```zig
// Send a feature report (first byte is the report ID).
_ = try device.sendFeatureReport(io, &.{ 0x02, 0xff, 0x00 });

// Request a feature report; set the first byte to the report ID you want.
var feature: [32]u8 = undefined;
feature[0] = 0x02;
const got = try device.getFeatureReport(io, &feature);
```

### Report descriptors

```zig
const size = try device.getReportDescriptorSize(io);

var descriptor: [4096]u8 = undefined;
const bytes = try device.getReportDescriptor(io, descriptor[0..size]);
```

## API overview

### `hidapi.Device`

An open `hidraw` file descriptor.

| Function | Description |
| --- | --- |
| `open(io, minor)` | Open `/dev/hidraw{minor}` read-write |
| `close(io)` | Close the descriptor |
| `read(io, buf)` | Read an input report from the interrupt IN endpoint |
| `write(io, buf)` | Write an output report (first byte is the report ID) |
| `getInputReport(io, buf)` | Request an input report over the control endpoint |
| `getFeatureReport(io, buf)` | Request a feature report over the control endpoint |
| `sendFeatureReport(io, data)` | Send a feature report over the control endpoint |
| `getReportDescriptorSize(io)` | Size of the HID report descriptor |
| `getReportDescriptor(io, buf)` | Copy the HID report descriptor into `buf` |
| `getRawName(io, buf)` | Vendor and product strings, UTF-8 |
| `getPhysicalLocation(io, buf)` | USB physical path, or Bluetooth MAC address |
| `getDeviceInfo(io)` | Bus type, vendor ID, and product ID as a `DeviceInfo` |
| `getBusType(io)` | Bus type only |
| `getVendorID(io)` | Vendor ID only |
| `getProductID(io)` | Product ID only |

For every call that takes a report buffer, the first byte is the report ID —
`0x00` for devices that do not use numbered reports — so the buffer must be one
byte longer than the report itself.

### `hidapi.DeviceInfo`

The `device` it was read from, plus the device's `bustype` (a `BUS` enum
covering `USB`, `BLUETOOTH`, `I2C`, and the rest of the kernel's bus types),
`vendor`, and `product` IDs.

### `hidapi.DeviceInfoIterator`

`init` then `next(io)` to walk the available `hidraw` nodes, as shown above.

## Permissions

`/dev/hidraw*` nodes are normally root-only, so `Device.open` will fail with
`error.HIDDeviceNoAccess` for an unprivileged process. Grant access with a udev
rule rather than running as root — for example, in
`/etc/udev/rules.d/70-hidraw.rules`:

```udev
KERNEL=="hidraw*", ATTRS{idVendor}=="1234", ATTRS{idProduct}=="5678", MODE="0660", GROUP="plugdev"
```

Then `udevadm control --reload-rules && udevadm trigger`, and make sure your
user is in the group you named.

## Cloning with Radicle

This repository is also published on [Radicle](https://radicle.xyz), a
peer-to-peer code collaboration network. Its Repository ID is:

```
rad:z2XSKZUPc81eR9a7RLZrJbZpkS4su
```

With the `rad` CLI installed and a local identity created (`rad auth --alias
<name>`), start your node and clone:

```sh
rad node start
rad clone rad:z2XSKZUPc81eR9a7RLZrJbZpkS4su
```

`rad clone` finds seeds seeding the repository through your node's routing
table, so the node needs to be running and connected. If discovery fails
because no seed has been found yet, name one directly:

```sh
rad clone rad:z2XSKZUPc81eR9a7RLZrJbZpkS4su --seed <NID>
```

The clone checks out the default branch (`main`) and leaves you seeding the
repository, so your node will serve it to other peers. `rad sync` pulls later
changes.

To publish work back, push to the `rad` remote and open a patch:

```sh
git push rad HEAD:refs/heads/my-change
rad patch open
```

The repository is delegated to a single key,
`did:key:z6MkoM8gqRFf1hARf3cSX2hhe7kgTfKSQpNksR9uKErWotKq`, which is what
authorizes changes to `main`.

## Development

A Nix flake provides the toolchain (Zig 0.16, `reuse`, `pinact`, and the
`rad` CLI):

```sh
nix develop
```

Build and test:

```sh
zig build
zig build test
```

The `enumerate` test opens real devices on the host, so its results depend on
what hardware is attached and on the permissions described above.

This repository follows the [REUSE](https://reuse.software/) specification for
licensing metadata and uses [typos](https://github.com/crate-ci/typos) for spell
checking:

```sh
reuse lint
typos
```

## License

MIT — see [`LICENSES/MIT.txt`](LICENSES/MIT.txt).

Copyright © 2024 Jeffrey C. Ollie.
