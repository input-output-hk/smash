# This is the derivation used by "stack --nix".
# It provides the system dependencies required for a stack build.
with import ./. {};

haskell.lib.buildStackProject {
  name = "stack-env";
  ghc = (import ../shell.nix { inherit pkgs; }).ghc.baseGhc;

  buildInputs =
    # Development libraries which may be necessary for the build.
    # Add remove libraries as necessary
    [ zlib openssl git systemd ];

  phases = ["nobuildPhase"];
  nobuildPhase = "mkdir -p $out";
}
