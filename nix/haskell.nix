############################################################################
# Builds Haskell packages with Haskell.nix
############################################################################
{ lib
, stdenv
, haskell-nix
, buildPackages
, config ? {}
# GHC attribute name
, compiler
# Source root directory
, src
# Enable profiling
, profiling ? config.haskellNix.profiling or false
, projectPackagesNames
# Disable basic auth by default:
, flags ? [ "disable-basic-auth" ]
}:
let

  # This creates the Haskell package set.
  # https://input-output-hk.github.io/haskell.nix/user-guide/projects/
  pkgSet = haskell-nix.cabalProject {
    inherit src;
    compiler-nix-name = compiler;
    modules = [

      # Allow reinstallation of Win32
      { nonReinstallablePkgs =
        [ "rts" "ghc-heap" "ghc-prim" "integer-gmp" "integer-simple" "base"
          "deepseq" "array" "ghc-boot-th" "pretty" "template-haskell"
          # ghcjs custom packages
          "ghcjs-prim" "ghcjs-th"
          "ghc-boot"
          "ghc" "array" "binary" "bytestring" "containers"
          "filepath" "ghc-boot" "ghc-compact" "ghc-prim"
          # "ghci" "haskeline"
          "hpc"
          "mtl" "parsec" "text" "transformers"
          "xhtml"
          # "stm" "terminfo"
        ];
      }
      {
        # Set flags
        packages = lib.genAttrs projectPackagesNames (_: {
          flags = lib.genAttrs flags (_: true);
        });
      }
      # TODO: Compile all local packages with -Werror:
      #{
      #  packages = lib.genAttrs projectPackagesNames
      #    (name: { configureFlags = [ "--ghc-option=-Werror" ]; });
      #}
    ];
  };
in
  pkgSet
