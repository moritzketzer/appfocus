{
  description = "Keyboard-driven app switcher for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "appfocus";
        version = "0.1.0";
        src = ./.;

        __noChroot = true;

        buildPhase = ''
          export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
          unset SDKROOT
          make SWIFTC=/usr/bin/swiftc
        '';

        installPhase = ''
          make install PREFIX=$out
        '';

        meta = {
          description = "Keyboard-driven app switcher for macOS";
          license = pkgs.lib.licenses.mit;
          platforms = pkgs.lib.platforms.darwin;
          mainProgram = "appfocus";
        };
      };
    };
}
