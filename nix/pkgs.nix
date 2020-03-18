# our packages overlay
pkgs: _: with pkgs; {
  iohkMonitoringHaskellPackages = import ./haskell.nix {
    inherit config
      lib
      stdenv
      haskell-nix
      buildPackages
      ;
  };
}
