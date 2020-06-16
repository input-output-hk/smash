############################################################################
#
# Hydra release jobset.
#
# The purpose of this file is to select jobs defined in default.nix and map
# them to all supported build platforms.
#
############################################################################

# The project sources
{ smash ? { outPath = ./.; rev = "abcdef"; }

# Function arguments to pass to the project
, projectArgs ? {
    inherit sourcesOverride;
    config = { allowUnfree = false; inHydra = true; };
    gitrev = smash.rev;
  }

# The systems that the jobset will be built for.
, supportedSystems ? [ "x86_64-linux" "x86_64-darwin" ]

# The systems used for cross-compiling (default: linux)
, supportedCrossSystems ? [ (builtins.head supportedSystems) ]

# A Hydra option
, scrubJobs ? true

# Dependencies overrides
, sourcesOverride ? {}

# Import pkgs, including IOHK common nix lib
, pkgs ? import ./nix { inherit sourcesOverride; }

}:

with (import pkgs.iohkNix.release-lib) {
  inherit pkgs;
  inherit supportedSystems supportedCrossSystems scrubJobs projectArgs;
  packageSet = import smash;
  gitrev = smash.rev;
};

with pkgs.lib;

let
  # restrict supported systems to a subset where tests (if exist) are required to pass:
  testsSupportedSystems = intersectLists supportedSystems [ "x86_64-linux" "x86_64-darwin" ];
  # Recurse through an attrset, returning all derivations in a list matching test supported systems.
  collectJobs' = ds: filter (d: elem d.system testsSupportedSystems) (collect isDerivation ds);
  # Adds the package name to the derivations for windows-testing-bundle.nix
  # (passthru.identifier.name does not survive mapTestOn)
  collectJobs = ds: concatLists (
    mapAttrsToList (packageName: package:
      map (drv: drv // { inherit packageName; }) (collectJobs' package)
    ) ds);

  jobs = {
    native = mapTestOn (__trace (__toJSON (packagePlatforms project)) (packagePlatforms project));
  } // (mkRequiredJob (concatLists [
    (collectJobs jobs.native.checks)
    (collectJobs jobs.native.libs)
    (collectJobs jobs.native.exes)
  ]));

in jobs
