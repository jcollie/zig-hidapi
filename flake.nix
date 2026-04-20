# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-hidapi";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    };
    zig = {
      url = "git+https://git.ocjtech.us/jeff/zig-overlay.git?ref=main";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      zig,
      ...
    }:
    let
      lib = nixpkgs.lib;
      platforms = lib.attrNames zig.packages;
      packages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = function: nixpkgs.lib.genAttrs platforms (system: function (packages system));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "zig-hidapi";
          nativeBuildInputs = [
            zig.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0"
            pkgs.pinact
            pkgs.reuse
          ];
        };
      });
    };
}
