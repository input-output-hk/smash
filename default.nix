{ system ? builtins.currentSystem
, crossSystem ? null
# allows to cutomize haskellNix (ghc and profiling, see ./nix/haskell.nix)
, config ? {}
# override scripts with custom configuration
, customConfig ? {}
# allows to override dependencies of the project without modifications,
# eg. to test build against local checkout of iohk-nix:
# nix build -f default.nix cardano-node --arg sourcesOverride '{
#   iohk-nix = ../iohk-nix;
# }'
, sourcesOverride ? {}
# pinned version of nixpkgs augmented with overlays (iohk-nix and our packages).
, pkgs ? import ./nix { inherit system crossSystem config sourcesOverride; }
, gitrev ? pkgs.iohkNix.commitIdFromGitRepoOrZero ./.git
}:
with pkgs; with commonLib;
let
  customConfig' = if customConfig ? services then customConfig else {
    services.smash = customConfig;
  };

  haskellPackages = recRecurseIntoAttrs
    # we are only intersted in listing the project packages:
    (selectProjectPackages smashHaskellPackages);
  scripts = callPackage ./nix/scripts.nix {
    customConfig = customConfig';
  };

  packages = {
    inherit haskellPackages scripts smash-exe smash-exe-testing cardano-node;
    inherit (haskellPackages.smash.identifier) version;

    # `tests` are the test suites which have been built.
    tests = collectComponents' "tests" haskellPackages;

    libs = collectComponents' "library" haskellPackages;

    exes = lib.recursiveUpdate (collectComponents' "exes" haskellPackages) {
      smash = { inherit smash-exe-testing; };
    };

    checks = recurseIntoAttrs {
      # `checks.tests` collect results of executing the tests:
      tests = collectChecks haskellPackages;
    };

    nixosTests = import ./nix/nixos/tests {
      inherit pkgs;
    };

    shell = import ./shell.nix {
      inherit pkgs;
      withHoogle = true;
    };
};
in packages
