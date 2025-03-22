{
  description = "zig-hidapi";

  inputs = {
    nixpkgs = {
      url = "nixpkgs/nixos-unstable";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
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
            pkgs.zig_0_14
            pkgs.hidapi
          ];
          buildInputs = [
            pkgs.hidapi
          ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.hidapi
          ];
        };
      }
    );
}
