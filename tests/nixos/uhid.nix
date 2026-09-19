# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# Runs the whole suite on a machine where it is root, which is what
# `/dev/uhid` needs.
#
# Without this, CI proves only that the library compiles: a runner has no HID
# devices, so the enumeration test finds an empty list and passes and every
# test that wants a device reports `SkipZigTest`. Here the suite creates the
# device it then talks to, so every assertion is against something known.

{ tests }:

{
  name = "zig-hidapi-uhid";

  nodes.machine =
    { config, ... }:
    {
      # `uhid` is the whole point of the machine. It is not in the default
      # module set, and without it `/dev/uhid` is simply absent and the tests
      # skip exactly as they do on a workstation -- which would look like a
      # pass.
      boot.kernelModules = [ "uhid" ];

      # The virtual device is created, probed and published by the HID core,
      # which means udev has to be running for the `/dev/hidraw*` node to
      # appear at all. It is on by default; this is a note rather than a
      # setting.

      environment.systemPackages = [ tests ];

      virtualisation = {
        cores = 2;
        memorySize = 1024;
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # If this is missing the tests below would skip rather than fail, so
    # check it here where the failure is legible.
    machine.succeed("test -c /dev/uhid")

    # No HID hardware in a virtual machine, so the tests that want real
    # devices skip. What this proves is that enumeration finds an empty list
    # without falling over, and that every unit test passes.
    print(machine.succeed("unit-tests 2>&1"))

    # The half that matters: invent a device, then enumerate it, open it, and
    # exchange reports with it.
    output = machine.succeed("virtual-device-tests 2>&1")
    print(output)

    # A skip here would mean `/dev/uhid` was not usable and the assertions
    # never ran, which the test runner reports as success. Catch that.
    assert "skipped" not in output.lower() or "0 skipped" in output.lower(), (
        "the uhid tests skipped, so nothing was actually tested:\n" + output
    )
  '';
}
