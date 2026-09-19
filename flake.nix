# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-hidapi";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    };
  };

  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      linuxSystems = builtins.filter (
        system: (lib.systems.elaborate system).isLinux
      ) lib.systems.flakeExposed;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      # Packages and checks are Linux-only: the package builds the test
      # binaries for the virtual machine test, and `pkgs.testers.runNixOSTest`
      # cannot even be evaluated for Darwin.
      forAllSystems = lib.genAttrs linuxSystems;

      # Dev shells are not. There is a macOS backend now, and a contributor on
      # a Mac needs the same Zig and the same tools -- and is the only person
      # who can actually run that backend.
      forAllShells = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        rec {
          tests = pkgs.callPackage ./package.nix { };
          default = tests;
        }
      );

      # Linux only, and not because of the library -- `pkgs.testers.runNixOSTest`
      # cannot be evaluated for Darwin at all, and `nix flake check` would try.
      checks = forAllSystems (
        system:
        let
          pkgs = makePackages system;
          tests = pkgs.callPackage ./package.nix { };
        in
        {
          inherit tests;
          uhid = pkgs.testers.runNixOSTest (import ./tests/nixos/uhid.nix { inherit tests; });
        }
      );

      devShells = forAllShells (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "zig-hidapi";
            nativeBuildInputs = [
              pkgs.git-pages-cli
              pkgs.pinact
              pkgs.radicle-node
              pkgs.reuse
              pkgs.typos
              pkgs.zig_0_16
            ];
          };
        }
      );
    };
}
