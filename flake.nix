{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }: flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells = {
        default = pkgs.mkShell {
          name = "SumSpec";
          buildInputs = [
            pkgs.ghc
            pkgs.cabal-install
            pkgs.haskell-language-server
            pkgs.fourmolu
            # pkgs.zlib
            # pkgs.pkg-config
          ];
          shellHook = ''
            source ./.env
          '';
        };

      };
    });
}
