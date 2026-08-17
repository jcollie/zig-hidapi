# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-hidapi";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
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
            pkgs.pinact
            pkgs.reuse
            pkgs.zig_0_16
          ];
        };
      });
    };
}
