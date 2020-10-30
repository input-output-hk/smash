# our packages overlay
pkgs: _: with pkgs;
  let
    compiler = config.haskellNix.compiler or "ghc865";
    src = haskell-nix.haskellLib.cleanGit {
      name = "smash-src";
      src = ../.;
    };
    projectPackagesNames = lib.attrNames (haskell-nix.haskellLib.selectProjectPackages
      (haskell-nix.cabalProject { inherit src; compiler-nix-name = compiler; }));
  in {

    inherit projectPackagesNames;


    smashHaskellPackages = callPackage ./haskell.nix {
      inherit compiler src projectPackagesNames;
    };

    smashTestingHaskellPackages = callPackage ./haskell.nix {
      inherit compiler src projectPackagesNames;
      flags = [ "testing-mode" ];
    };

  # Grab the executable component of our package.
  inherit (smashHaskellPackages.smash.components.exes)
      smash-exe;

  smash-exe-testing = smashTestingHaskellPackages.smash.components.exes.smash-exe;

}
