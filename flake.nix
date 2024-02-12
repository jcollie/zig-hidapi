{
  description = "zig-usbnhid";

  inputs = {
    nixpkgs = {
      url = "nixpkgs/nixos-unstable";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
    make-shell = {
      url = "github:ursi/nix-make-shell";
    };
    zig = {
      url = "github:mitchellh/zig-overlay";
    };
    # zls = {
    #   url = "github:zigtools/zls";
    #   inputs.nixpkgs.follows = "nixpkgs";
    #   inputs.zig-overlay.follows = "zig";
    #   inputs.flake-utils.follows = "flake-utils";
    # };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs: let
    overlays = [
      # (
      #   final: prev: {
      #     zigpkgs = inputs.zig.packages.${prev.system};
      #   }
      # )
    ];
    systems = builtins.attrNames inputs.zig.packages;
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {
          inherit overlays system;
        };
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.hidapi
            inputs.zig.packages.${system}.master
            # inputs.zls.packages.${system}.zls
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
