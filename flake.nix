{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }: flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
      # The sumspec tool, with its dependencies from nixpkgs (prebuilt in
      # the binary cache). The tests run with cabal, not here.
      sumspec = pkgs.haskell.lib.justStaticExecutables
        (pkgs.haskell.lib.dontCheck
          (pkgs.haskellPackages.callCabal2nix "sumspec" ./. { }));
    in
    {
      packages.default = sumspec;

      apps.default = flake-utils.lib.mkApp { drv = sumspec; };

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
