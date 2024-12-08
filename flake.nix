{
  description = "zig-hidapi";

  inputs = {
    nixpkgs = {
      url = "nixpkgs/nixos-unstable";
    };
    zig = {
      url = "github:mitchellh/zig-overlay";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
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
          nativeBuildInputs = [
            pkgs.hidapi
            zig.packages.${system}.master
          ];
          buildInputs = [
            pkgs.hidapi
          ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.hidapi
          ];
          shellHook = ''
            name="zig-hidapi"
          '';
        };
        packages.default = pkgs.zigStdenv.mkDerivation {
          pname = "zig-hidapi";
          version = "0.1.0";
          buildInputs = [pkgs.hidapi];
          src = ./.;
        };
      }
    );
}
