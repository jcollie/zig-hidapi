<!--
SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-hidapi

A Zig library for talking to USB and Bluetooth HID devices, without linking
the C [hidapi](https://github.com/libusb/hidapi) library.

On Linux and FreeBSD it issues the `HIDIOC*` ioctls directly against
`/dev/hidraw*`, and on Linux it reads `/sys/class/hidraw` for everything that
can be learned without opening a device, so a Linux build links no C at all.
It is built on Zig 0.16's `std.Io`
interface, so every blocking operation is dispatched through the caller's I/O
implementation rather than blocking a thread outright, and it allocates
nothing: every buffer it needs is one the caller supplies.

## Supported systems

| System | Interface | Status |
| --- | --- | --- |
| Linux | `hidraw` and `/sys/class/hidraw` | supported |
| FreeBSD | `hidraw(4)` | supported |
| Windows | HIDCLASS through `NtDeviceIoControlFile` | supported |
| macOS | IOKit `IOHIDManager` | supported |

Building for a system with no backend is a compile error naming the ones there
are, rather than a failure somewhere deeper.

On Windows every request goes through `NtDeviceIoControlFile` with the
`IOCTL_HID_*` codes, rather than through the `HidD_*` wrappers in `hid.dll`,
so reads are cancelable and can take a timeout. The Win32 declarations come
from [zigwin32](https://github.com/marlersoft/zigwin32), which is the only
dependency this library has and is fetched only when building for Windows.

macOS is the one backend shaped differently from the inside, because the
platform is: input reports arrive on a callback delivered by a `CFRunLoop`,
whether anyone is reading or not, so an open device owns a task running that
loop and a queue for what the callback delivers. Three things follow that a
caller can see:

- **`OpenOptions.input_queue` is required on macOS**, where the other three
  backends ignore it. It is the buffer reports land in between reads, and it
  is the caller's so that the library still allocates nothing.
  `Device.takeDroppedReports` says how many were lost because it was full,
  because losing input silently is worse than losing it loudly.
- **Each open device holds one unit of concurrency** for its whole life, so an
  `Io` with a bounded `concurrent_limit` can refuse to open one. That is why
  `ConcurrencyUnavailable` is in `OpenError` on every target.
- **Input Monitoring.** Since macOS 10.15, opening a HID device needs that
  privacy permission, and without it `open` reports `error.AccessDenied`.
  Enumeration does not need it. For a command-line program the grant attaches
  to the terminal emulator rather than to your binary, and under a debugger it
  is the debugger that must be granted, both of which surprise everyone the
  first time. A daemon cannot show the consent dialog at all and has to be
  pre-approved.

Unlike the C hidapi, this library does **not** open devices exclusively by
default. Seizing a device stops it working for everything else on the machine
for as long as it is held; `OpenOptions.exclusive` asks for it when that is
what you want.

Two Windows limitations are worth knowing before you rely on them:

- **`getReportDescriptor` rebuilds the descriptor rather than reading it.**
  The HID class driver keeps only its own parsed form and never serves the
  original bytes to user mode, so there is nothing to read. What comes back
  describes the same device — same reports, same fields, same bit positions —
  and is *not* byte-for-byte what the device sent, because the parsed form has
  lost where the padding was and how the items were grouped. Do not compare
  descriptors for equality across platforms.

  Rebuilding needs working memory, and this library allocates none, so it
  happens only for a device opened with `OpenOptions.descriptor_scratch`:

  ```zig
  var scratch: [hidapi.Device.recommended_descriptor_scratch]u8 = undefined;
  try device.open(io, id, .{ .descriptor_scratch = &scratch });
  ```

  Without it — and on a device whose parsed form this library cannot read —
  the answer is `error.Unsupported`, as before. `recommended_descriptor_scratch`
  is zero on the other three backends, which read the descriptor directly, so
  portable code can pass it everywhere and cost nothing.
  `Device.getPreparsedData` still offers the parsed form to a caller who wants
  it raw.
- **Keyboards and pointing devices cannot be read.** The system holds them
  exclusively, so they open for metadata only: they enumerate and describe
  themselves perfectly well, and `read` and `write` report
  `error.AccessDenied`.

## Requirements

- Zig 0.16
- Linux with the `hidraw` driver (`CONFIG_HIDRAW`), i.e. `/dev/hidraw*` present
- or FreeBSD 13 or later with `hidraw(4)` attached — the default from 14.2,
  and before that `hw.usb.usbhid.enable=1` in `/boot/loader.conf` together with
  `usbhid` in `kld_list` in `/etc/rc.conf`

FreeBSD's `hidraw(4)` implements Linux's request set deliberately, so an open
device behaves identically on the two. Two things differ and are worth
knowing. The request *numbers* are not the same — BSD encodes them differently
and FreeBSD numbers its from a different group — which the library handles and
you never see. Enumeration is the visible one: FreeBSD has no sysfs, so it has
to open each node to learn anything about it, and an unprivileged process
without a `devfs.rules` entry therefore sees **nothing** where the same process
on Linux would see everything and merely be unable to open it.

## hidinfo

The package ships one program: `lsusb -v` for HID.

```console
$ zig build run -- --vendor 046d
046d:c090 [USB] Logitech G703 LIGHTSPEED Wireless Gaming Mouse w/ HERO (49D858E2)
  id             /dev/hidraw4
  bus            USB
  usage          0001:0002  (Mouse)
  interface      0
  release        22.02
  location       usb-0000:0b:00.3-2.3/input0
  descriptor     67 bytes
  input report
       0..15   16x1   [Data,Var,Abs] 0..1  usage 0009:0001..0010  (Button)
      16..47    2x16  [Data,Var,Rel] -32767..32767  usage 0001:0030 0001:0031  (X)
      48..55    1x8   [Data,Var,Rel] -127..127  usage 0001:0038  (Wheel)
      56..63    1x8   [Data,Var,Rel] -127..127  usage 000c:0238  (AC Pan)
```

`--short` gives a line per device and opens nothing, `--raw` adds a hex dump of
the descriptor, and `--vendor`, `--product` and `--usage` narrow the list.
Enumeration needs no permissions, so the listing is always complete; a device
this process may not open says so and the rest carry on.

It is also the library's worked example — everything it does is something a
dependent will want to do — so `tools/hidinfo.zig` is the place to look for how
the pieces fit together.

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

`read` waits indefinitely, so anything that has to stay responsive wants
`readTimeout` instead, which returns `null` when nothing arrived in time:

```zig
const waited = try device.readTimeout(io, &in, .{
    .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake },
});

// A zero duration is a non-blocking poll: take whatever is already waiting.
const polled = try device.readTimeout(io, &in, .{
    .duration = .{ .raw = .zero, .clock = .awake },
});
```

There is deliberately no non-blocking *mode* to set, the way the C hidapi has
one — a mode is a second way of saying what the timeout already says. Note
that `null` and a zero-length report are different answers, since a device may
legitimately send a report with no data.

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

### Making sense of a report

A report on its own is a handful of opaque bytes. The report descriptor says
what is in them, and `hidapi.descriptor` reads it:

```zig
var buf: [hidapi.max_report_descriptor_len]u8 = undefined;
const len = try device.getReportDescriptorLen(io);
const bytes = try device.getReportDescriptor(io, buf[0..len]);

var parser: hidapi.descriptor.Parser = .init(bytes);
while (try parser.next()) |field| {
    if (field.kind != .input or field.flags.constant) continue;
    for (0..field.count) |i| {
        const index: u16 = @intCast(i);
        const value = field.extract(report, index) orelse continue;
        std.debug.print("{x:0>8} = {d}\n", .{ field.usageAt(index) orelse 0, value });
    }
}
```

For the mouse on my desk that prints the sixteen buttons, then X, Y, the wheel
and AC Pan, each with its usage and its value — and the signed fields come back
signed, because a field whose logical minimum is negative is the only thing
that says so.

Each `Field` is one main item: `report_id`, `kind`, `bit_offset`, `bit_size`,
`count`, the usage page and usages, the logical and physical ranges, the unit,
the flags, and the `collections` enclosing it. `extract(body, index)` reads one
element out of a report body — that is the report *without* any leading report
ID byte, so pass `report[1..]` for a device that uses them.
`descriptor.reportLength` gives the length of a report, counting the ID byte
where there is one.

Reports are built the same way round. `insert(body, index, value)` writes one
element and touches only that field's bits, so several fields go into one
report in any order:

```zig
var report: [1]u8 = @splat(0);
try leds.insert(&report, 0, 1); // Num Lock on
try leds.insert(&report, 2, 1); // Scroll Lock on
_ = try device.write(io, &report);
```

It refuses a value that will not fit the field rather than truncating it, and
one outside the declared logical range rather than clamping it — silently
writing something other than what was asked is how a device ends up doing
something other than what was meant. A range of zero to zero means the
descriptor declared none, and then only the field's width bounds the value.

There are two cheaper levels for code that wants less. `descriptor.firstUsage`
answers only what the device is, which is what enumeration uses to fill in
`usage_page` and `usage`. `descriptor.Iterator` walks the raw items for code
that wants the descriptor exactly as written.

Nothing in it allocates: a `Parser` is a value you own, and the slices a
`Field` hands back point into it and stay valid until the next `next` — the
same rule `Enumerator` follows.

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
| `read(io, buf)` | Read an input report, waiting for one |
| `readTimeout(io, buf, timeout)` | …giving up after `timeout`; `null` if none came |
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

### `hidapi.descriptor`

Reading a report descriptor. `Parser` yields a `Field` per main item with its
position, size, usages and ranges resolved; `Field.extract` reads a value out
of a report; `Iterator` walks the raw items; `firstUsage` answers the cheap
question. See above.

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

On FreeBSD the equivalent is a `devfs.rules` entry, in `/etc/devfs.rules`:

```
[localrules=10]
add path 'hidraw*' mode 0660 group operator
```

with `devfs_system_ruleset="localrules"` in `/etc/rc.conf`, and your user in
the group. Note that on FreeBSD this affects enumeration too, not just
opening: without it the device list comes back empty.

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
- [github.com/jcollie/zig-hidapi](https://github.com/jcollie/zig-hidapi), which
  also runs the suite on macOS and Windows — the two platforms the Forgejo
  runners cannot boot
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
zig build              # hidinfo into zig-out/bin
zig build run -- -h    # ...and run it
zig build test
zig build check       # compile for every supported target, without linking
zig build docs        # API reference into zig-out/docs
zig build docs-serve  # ...and serve it at http://127.0.0.1:8000/
```

`check` compiles the library as an object for each supported target and two
architectures apiece. Building an object rather than linking one is what lets
a Linux machine compile a backend it could never link — no framework, import
library or platform SDK has to be present — so it is the cheap way to keep
every backend honest from one workstation. What it cannot prove is that the
symbols a backend names actually exist, which is why CI also runs the suite on
macOS and Windows runners.

The documentation is a WebAssembly viewer that fetches `sources.tar`, so it has
to be served over HTTP; opening `zig-out/docs/index.html` from the filesystem
shows an empty page, which is why there is a step that serves it and why `zig
std` works the same way. `-Ddocs-port=N` chooses another port. CI publishes the
same output to [the address above][docs].

The `enumerate` test lists the real devices on the host, and the
read-only-operations test opens as many of them as it is allowed to, so both
depend on what hardware is attached and on the permissions described above.
The second reports `SkipZigTest` when it could open none.

The tests in `tests/` do not depend on hardware at all: they invent a HID
device through Linux's `uhid`, with a report descriptor and strings of their
own choosing, and then enumerate it, open it and exchange reports with it
through this library. `/dev/uhid` is root-only, so they report `SkipZigTest`
on a workstation and do their work in a NixOS virtual machine, which is also
what CI runs:

```sh
nix flake check
```

This repository follows the [REUSE](https://reuse.software/) specification for
licensing metadata and uses [typos](https://github.com/crate-ci/typos) for spell
checking:

```sh
reuse lint
typos
zig fmt --check --exclude zig-pkg .
```

`zig-pkg` is where Zig materialises a fetched dependency, so after anything
has built for Windows it holds the Win32 bindings. It is in `.gitignore`, but
`zig fmt` does not honour that the way `reuse` does, hence the `--exclude`.

## References cited

What this library was written against. The specifications and headers are the
authority for the numbers and structures; the two implementations are cited
because they document behaviour no specification does.

- Apple. *IOHIDManager*. Apple Developer Documentation.
  <https://developer.apple.com/documentation/iokit/iohidmanager>
- Apple. *kIOHIDReportDescriptorKey*. Apple Developer Documentation.
  <https://developer.apple.com/documentation/hiddriverkit/kiohidreportdescriptorkey>
  — documented for DriverKit only, though `IOHIDDevice` publishes it for user
  space as well, which the macOS backend relies on.
- The FreeBSD Project. *hidraw(4) — raw access to HID devices*. FreeBSD Manual
  Pages. <https://man.freebsd.org/cgi/man.cgi?query=hidraw&sektion=4> — note
  that this page omits `HIDIOCGRAWUNIQ`, which the header does define.
- The FreeBSD Project. *sys/dev/hid/hidraw.h*.
  <https://cgit.freebsd.org/src/plain/sys/dev/hid/hidraw.h> — the authority
  for FreeBSD's request numbers, which are in group `'U'` and differ from
  Linux's in value and, for `HIDIOCGRDESC`, in shape.
- libusb. *HIDAPI — a multi-platform library for communication with HID
  devices*. <https://github.com/libusb/hidapi> — the C library this one is an
  alternative to, and the reference for the macOS teardown sequence and the
  Windows metadata-only open.
- The Linux Kernel documentation. *HIDRAW — Raw Access to USB and Bluetooth
  Human Interface Devices*. <https://docs.kernel.org/hid/hidraw.html>
- The Linux Kernel documentation. *uhid — User-space I/O driver support for
  HID subsystem*. <https://docs.kernel.org/hid/uhid.html> — the protocol the
  test suite implements to invent a device to test against.
- marlersoft. *zigwin32 — autogenerated Zig bindings for the Win32 API*.
  <https://github.com/marlersoft/zigwin32>
- Microsoft. *IOCTL_HID_GET_COLLECTION_DESCRIPTOR*. Microsoft Learn.
  <https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/hidclass/ni-hidclass-ioctl_hid_get_collection_descriptor>
- Microsoft. *IOCTL_HID_GET_REPORT_DESCRIPTOR*. Microsoft Learn.
  <https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/hidport/ni-hidport-ioctl_hid_get_report_descriptor>
  — in `hidport.h`, and so not reachable from user mode; between this and the
  entry above lies the reason `getReportDescriptor` is unsupported on Windows.
- signal11. *Mac: HID Manager segfaults after registering, then unregistering
  input report callback*. Issue #116.
  <https://github.com/signal11/hidapi/issues/116>
- USB Implementers Forum. *Device Class Definition for Human Interface Devices
  (HID), Version 1.11*. 27 June 2001.
  <https://www.usb.org/sites/default/files/hid1_11.pdf> — section 6.2.2 is the
  report descriptor item encoding this library parses.
- The Wine Project. *wine/dlls/hid/hidd.c*.
  <https://github.com/wine-mirror/wine/blob/master/dlls/hid/hidd.c> — shows
  the `HidD_*` functions to be one-to-one wrappers around the `IOCTL_HID_*`
  requests, which is what justifies issuing those directly.
- winsdk-10. *hidclass.h (Windows Driver Kit)*.
  <https://github.com/tpn/winsdk-10/blob/master/Include/10.0.14393.0/shared/hidclass.h>
- The Zig Software Foundation. *Zig 0.16.0 Release Notes*.
  <https://ziglang.org/download/0.16.0/release-notes.html>

## License

MIT — see [`LICENSES/MIT.txt`](LICENSES/MIT.txt).

Copyright © 2024 Jeffrey C. Ollie.
