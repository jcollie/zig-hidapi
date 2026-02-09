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
      packages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems =
        function:
        nixpkgs.lib.genAttrs [
          "aarch64-linux"
          "aarch64-darwin"
          "x86_64-darwin"
          "x86_64-linux"
        ] (system: function (packages system));

    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "zig-hidapi";
          nativeBuildInputs = [
            zig.packages.${pkgs.stdenv.hostPlatform.system}.master
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
      });
    };
}
