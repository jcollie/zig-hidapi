# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-hidapi";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    };
    # Mine, and not the `zon2nix` in nixpkgs, which is a different program
    # taking different options.
    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      zon2nix,
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
      forAllSystems = lib.genAttrs linuxSystems;
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

      devShells = forAllSystems (
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
              # Wrapped so that the Zig it shells out to for `zig env` is the
              # one this project builds with, rather than whatever happens to
              # be on the caller's PATH.
              (pkgs.symlinkJoin {
                name = "zon2nix";
                paths = [ zon2nix.packages.${pkgs.stdenv.hostPlatform.system}.zon2nix ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/zon2nix \
                    --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_16 ]}
                '';
              })
              pkgs.zig_0_16
            ];
          };
        }
      );
    };
}
