# our packages overlay
pkgs: _: with pkgs; {
  smashHaskellPackages = import ./haskell.nix {
    inherit config
      lib
      stdenv
      haskell-nix
      buildPackages
      ;
  };
}
