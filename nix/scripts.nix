{ pkgs, lib, iohkNix, customConfig }:
let
  blacklistedEnvs = [ "selfnode" "shelley_selfnode" "latency-tests" "mainnet-ci" ];
  environments = lib.filterAttrs (k: v: (!builtins.elem k blacklistedEnvs)) iohkNix.cardanoLib.environments;
  mkStartScripts = envConfig: let
    systemdCompat.options = {
      systemd.services = lib.mkOption {};
      services.postgresql = lib.mkOption {};
      users = lib.mkOption {};
      environment = lib.mkOption {};
    };
    eval = let
      extra = {
        internal.smashPackages = pkgs;
        services.smash = {
          enable = true;
          environment = envConfig;
          environmentName = envConfig.name;
        };
      };
    in lib.evalModules {
      prefix = [];
      modules = import nixos/module-list.nix ++ [ systemdCompat customConfig extra ];
      args = { inherit pkgs; };
    };
  in {
    smash = eval.config.services.smash.script;
  };
in iohkNix.cardanoLib.forEnvironmentsCustom mkStartScripts environments // { inherit environments; }
