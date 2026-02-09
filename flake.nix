{
  description = "zig-hidapi";

  inputs = {
    nixpkgs = {
      url = "nixpkgs/nixos-unstable";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        flake-compat.follows = "flake-compat";
      };
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    zig,
    ...
  }: let
  in
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
        };
      in {
        devShells.default = pkgs.mkShell {
          name = "zig-hidapi";
          nativeBuildInputs = [
            zig.packages.${system}.master
            # pkgs.zig_0_14
            # pkgs.hidapi
          ];
          buildInputs = [
            # pkgs.hidapi
          ];
          # LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
          #   # pkgs.hidapi
          # ];
        };
      }
    );
}
