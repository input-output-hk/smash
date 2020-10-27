# our packages overlay
pkgs: _: with pkgs;
  let
    compiler = config.haskellNix.compiler or "ghc865";
  in {
    smashHaskellPackages = callPackage ./haskell.nix {
      inherit compiler;
    };

  # Grab the executable component of our package.
  inherit (smashHaskellPackages.smash.components.exes)
      smash-exe;

}
