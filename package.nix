# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# The test executables, built and installed rather than run.
#
# There is deliberately no package of the library itself. A Zig library is
# consumed as source through the Zig build system -- a dependent adds it to its
# `build.zig.zon` and imports the module -- so there is no artifact to install
# and nothing a Nix package of it could usefully contain. What Nix *is* needed
# for is the virtual machine test: `tests/virtual_device.zig` invents a HID
# device through `/dev/uhid`, which is root-only, so the suite has to run
# somewhere that it is root, and that machine needs the binaries prebuilt
# rather than a Zig toolchain and a writable cache.
{
  lib,
  stdenv,
  zig_0_16,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "zig-hidapi-tests";
  version = "0.0.3";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
      ./tests
      ./tools
    ];
  };

  nativeBuildInputs = [ zig_0_16 ];

  # `test-exe` installs the test binaries; the default step would install
  # nothing, since the library produces no artifact.
  zigBuildFlags = [ "test-exe" ];

  # The tests are the product, so running them here would be running them
  # twice -- and the sandbox is not root and has no `/dev/uhid`, so the half
  # that matters would report `SkipZigTest` anyway. The virtual machine test
  # is what runs them.
  doCheck = false;

  meta = {
    description = "Test executables for zig-hidapi";
    homepage = "https://git.jcollie.dev/jeff/zig-hidapi";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
