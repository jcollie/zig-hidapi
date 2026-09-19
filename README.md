<!--
SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-hidapi

A Zig library for talking to USB and Bluetooth HID devices, without linking
the C [hidapi](https://github.com/libusb/hidapi) library.

On Linux it issues the `HIDIOC*` ioctls directly against `/dev/hidraw*` and
reads `/sys/class/hidraw` for everything that can be learned without opening a
device, so a Linux build links no C at all. It is built on Zig 0.16's `std.Io`
interface, so every blocking operation is dispatched through the caller's I/O
implementation rather than blocking a thread outright, and it allocates
nothing: every buffer it needs is one the caller supplies.

## Supported systems

| System | Interface | Status |
| --- | --- | --- |
| Linux | `hidraw` and `/sys/class/hidraw` | supported |
| FreeBSD | `hidraw(4)` | planned |
| Windows | HIDCLASS through `NtDeviceIoControlFile` | planned |
| macOS | IOKit `IOHIDManager` | planned |

Building for a system with no backend is a compile error naming the ones there
are, rather than a failure somewhere deeper.

## Requirements

- Zig 0.16
- Linux with the `hidraw` driver (`CONFIG_HIDRAW`), i.e. `/dev/hidraw*` present

## Installation

Fetch the package into your `build.zig.zon`:

```sh
zig fetch --save git+https://git.jcollie.dev/jeff/zig-hidapi.git
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

    var scratch: [hidapi.Enumerator.recommended_scratch]u8 = undefined;
    var devices: hidapi.Enumerator = undefined;
    try devices.init(io, &scratch, .{});
    defer devices.deinit(io);

    while (try devices.next(io)) |info| {
        std.debug.print("{f} at {f}\n", .{ info, &info.id });
    }
}
```

which prints something like

```
046d:c090 [USB] Logitech G703 LIGHTSPEED Wireless Gaming Mouse w/ HERO (49D858E2) at /dev/hidraw4
1050:0407 [USB] Yubico YubiKey OTP+FIDO+CCID at /dev/hidraw2
```

**Enumerating does not open anything.** On Linux that means it needs no
permissions at all — `/sys/class/hidraw` is world readable where
`/dev/hidraw*` is not — so an unprivileged process with no udev rule installed
still sees every device attached, and only finds out what it may talk to when
it tries to open one. It also means the `DeviceInfo` you get back is a plain
value with nothing to close and no lifetime to track: copy it, keep it, print
it, compare it.

The scratch buffer belongs to the enumerator until `deinit` and is the caller's
again afterwards. `recommended_scratch` is a size that works;
`hidapi.Enumerator.min_scratch` is the floor below which `init` returns
`error.BufferTooSmall`.

### Opening a device

`DeviceInfo.id` is all `Device.open` needs, and it is a value rather than a
slice, so it can outlive the enumerator that produced it — which is how a
program picks a device once and opens it later.

```zig
var scratch: [hidapi.Enumerator.recommended_scratch]u8 = undefined;
var devices: hidapi.Enumerator = undefined;
try devices.init(io, &scratch, .{ .vendor_id = 0x046d });
defer devices.deinit(io);

const id = while (try devices.next(io)) |info| {
    if (info.usage_page == 0xff00) break info.id;
} else return error.NoSuchDevice;

var device: hidapi.Device = undefined;
try device.open(io, id, .{});
defer device.close(io);
```

A `Device` is storage you own and use through a pointer, and it must not be
moved between `open` and `close`.

`open` reports `error.DeviceNotFound` when nothing answers to that ID, which
includes a device unplugged since it was enumerated, and `error.AccessDenied`
when permissions deny it.

### Reading and writing reports

**Every buffer starts with the report ID**, which is `0x00` for a device that
does not use numbered reports, so a sixteen byte report is seventeen bytes of
buffer.

```zig
// Write an output report.
var out: [17]u8 = @splat(0);
out[0] = 0x00;
out[1] = 0x42;
_ = try device.write(io, &out);

// Read an input report. This waits until the device sends one, so a device
// that is simply idle never returns from it.
var in: [64]u8 = undefined;
const report = try device.read(io, &in);
std.debug.print("read {d} bytes\n", .{report.len});
```

`read` returns `error.DeviceDisconnected` when the device goes away, which is
the ordinary end of a read loop rather than a failure to report.

### Feature reports

```zig
// Send a feature report (first byte is the report ID).
_ = try device.sendFeatureReport(io, &.{ 0x02, 0xff, 0x00 });

// Request a feature report; set the first byte to the report ID you want.
var feature: [32]u8 = undefined;
feature[0] = 0x02;
const got = try device.getFeatureReport(io, &feature);
std.debug.print("feature report: {x}\n", .{got});
```

### Report descriptors

```zig
const len = try device.getReportDescriptorLen(io);

var descriptor: [hidapi.max_report_descriptor_len]u8 = undefined;
const bytes = try device.getReportDescriptor(io, descriptor[0..len]);
std.debug.print("descriptor: {d} bytes\n", .{bytes.len});
```

## API overview

The full reference is generated from the doc comments in the source, covers
every declaration, and is published at [jeff.jcollie.page/zig-hidapi][docs].
CI rebuilds it whenever `main` goes green. What follows is a summary.

[docs]: https://jeff.jcollie.page/zig-hidapi/

### `hidapi.Enumerator`

Walks the devices attached to the system, filling a `DeviceInfo` at a time into
caller-supplied scratch. `init(io, scratch, options)`, `next(io)`,
`deinit(io)`; `find(io, scratch, options, out)` is the one-device shorthand.

`Options` carries `vendor_id` and `product_id` filters, and `usages` and
`strings` flags that trade completeness for speed — on Linux `strings` is four
extra sysfs reads per device and `usages` means reading and walking a report
descriptor for each.

### `hidapi.DeviceInfo`

What is known about a device without talking to it: `id`, `vendor_id`,
`product_id`, `release_number`, `usage_page`, `usage`, `interface_number`,
`bus_type`, `native_bus`, and four strings — `manufacturer`, `product`,
`serial_number` and `physical_location`.

The strings are `hidapi.Str`, held inline rather than allocated, so the whole
record copies freely with no lifetime attached. `str.slice()` returns `null`
for a string the device does not report, which is a different answer from an
empty one, and `str.truncated` says whether a longer string was cut.

`serial_number` is the only field that survives a replug, and so the only
sound way to recognise the same physical device in a later run.

### `hidapi.Device`

An open device. Caller-owned storage, used through a pointer.

| Function | Description |
| --- | --- |
| `open(io, id, options)` | Open the device `id` names |
| `close(io)` | Close it |
| `read(io, buf)` | Read an input report from the interrupt IN endpoint |
| `write(io, report)` | Write an output report |
| `getInputReport(io, buf)` | Request an input report over the control endpoint |
| `getFeatureReport(io, buf)` | Request a feature report over the control endpoint |
| `sendFeatureReport(io, report)` | Send a feature report over the control endpoint |
| `getReportDescriptorLen(io)` | Size of the HID report descriptor |
| `getReportDescriptor(io, buf)` | Copy the HID report descriptor into `buf` |
| `getInfo(io, out)` | What the open device says about itself |

`getInfo` answers less than enumeration does, because it asks the HID device
rather than the system: on Linux the manufacturer and product strings live on
the USB device a couple of levels up, and the HID device reports only the two
run together. Keep the `DeviceInfo` the enumerator gave you rather than
re-reading it from the open device.

### `hidapi.BusType`

How a device is attached: `usb`, `bluetooth`, `i2c`, `spi`, `virtual`,
`other`, or `unknown`. Deliberately short and exhaustive; whatever number the
system actually reported is kept separately on `DeviceInfo.native_bus`, so
nothing is lost by mapping into it.

### Errors

Every error set is named and explicit — `hidapi.OpenError`,
`hidapi.ReadError` and the rest, or `hidapi.AnyError` for all of them at once.
The ones worth knowing apart:

- `AccessDenied` — the process may not talk to this device. See below.
- `DeviceNotFound` — nothing answers to that ID. Enumerate again.
- `DeviceDisconnected` — it was there and now is not. Stop.
- `DeviceRefused` — the system or the device rejected the request. The
  underlying `errno` is logged at warning level first.

## Permissions

`/dev/hidraw*` nodes are normally root-only, so `Device.open` will fail with
`error.AccessDenied` for an unprivileged process. Enumeration is unaffected —
it reads sysfs and needs no permissions — so the usual symptom is a program
that lists a device perfectly well and then cannot open it.

Grant access with a udev rule rather than running as root — for example, in
`/etc/udev/rules.d/70-hidraw.rules`:

```udev
KERNEL=="hidraw*", ATTRS{idVendor}=="1234", ATTRS{idProduct}=="5678", MODE="0660", GROUP="plugdev"
```

Then `udevadm control --reload-rules && udevadm trigger`, and make sure your
user is in the group you named.

## Where this lives

The repository is hosted on my Forgejo instance, which is where the issue
tracker and CI are:

```sh
git clone https://git.jcollie.dev/jeff/zig-hidapi.git
```

The mirrors carry the same history and are there so that the code outlives any
one host:

- [tangled.org/jcollie.dev/zig-hidapi](https://tangled.org/jcollie.dev/zig-hidapi)
- [codeberg.org/jcollie/zig-hidapi](https://codeberg.org/jcollie/zig-hidapi)
- Radicle, as `rad:z2XSKZUPc81eR9a7RLZrJbZpkS4su` — see below

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

A Nix flake provides the toolchain (Zig 0.16, `reuse`, `pinact`,
`git-pages-cli`, and the `rad` CLI):

```sh
nix develop
```

Build and test:

```sh
zig build
zig build test
zig build docs        # API reference into zig-out/docs
zig build docs-serve  # ...and serve it at http://127.0.0.1:8000/
```

The documentation is a WebAssembly viewer that fetches `sources.tar`, so it has
to be served over HTTP; opening `zig-out/docs/index.html` from the filesystem
shows an empty page, which is why there is a step that serves it and why `zig
std` works the same way. `-Ddocs-port=N` chooses another port. CI publishes the
same output to [the address above][docs].

The `enumerate` test lists the real devices on the host, and the
read-only-operations test opens as many of them as it is allowed to, so both
depend on what hardware is attached and on the permissions described above.
The second reports `SkipZigTest` when it could open none.

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
