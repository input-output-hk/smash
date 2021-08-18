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
, postgresql
# Disable basic auth by default:
, flags ? [ "disable-basic-auth" ]
}:
let
  preCheck = ''
    echo pre-check
    initdb --encoding=UTF8 --locale=en_US.UTF-8 --username=postgres $NIX_BUILD_TOP/db-dir
    postgres -D $NIX_BUILD_TOP/db-dir -k /tmp &
    PSQL_PID=$!
    sleep 10
    if (echo '\q' | psql -h /tmp postgres postgres); then
      echo "PostgreSQL server is verified to be started."
    else
      echo "Failed to connect to local PostgreSQL server."
      exit 2
    fi
    ls -ltrh $NIX_BUILD_TOP
    DBUSER=nixbld
    DBNAME=nixbld
    export SMASHPGPASSFILE=$NIX_BUILD_TOP/pgpass-test
    echo "/tmp:5432:$DBUSER:$DBUSER:*" > $SMASHPGPASSFILE
    cp -vir ${../schema} ../schema
    chmod 600 $SMASHPGPASSFILE
    psql -h /tmp postgres postgres <<EOF
      create role $DBUSER with createdb login password '$DBPASS';
      alter user $DBUSER with superuser;
      create database $DBNAME with owner = $DBUSER;
      \\connect $DBNAME
      ALTER SCHEMA public   OWNER TO $DBUSER;
    EOF
  '';

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
          # Advice from angerman
          "directory" "process" "terminfo" "time" "unix"
        ];
      }
      {
        # Set flags
        packages = lib.genAttrs projectPackagesNames (_: {
          flags = lib.genAttrs flags (_: true);
        });
      }
      {
        packages.smash.components.tests.db-spec-test = {
          build-tools = [ postgresql ];
          inherit preCheck;
        };
      }
      {
        packages.cardano-db-sync.package.extraSrcFiles = ["../schema/*.sql"];
        packages.cardano-db-sync-extended.package.extraSrcFiles = ["../cardano-db-sync/Setup.hs" "../schema/*.sql"];
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
