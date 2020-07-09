{ config, lib, pkgs, ... }:

let
  cfg = config.services.smash;
in {

  options = {
    services.smash = {
      enable = lib.mkEnableOption "enable the smash server";
      script = lib.mkOption {
        internal = true;
        type = lib.types.package;
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.smashHaskellPackages.smash.components.exes.smash-exe or (import ../. {}).smashHaskellPackages.smash.components.exes.smash-exe;
      };
      configFile = lib.mkOption {
        type = lib.types.path;
        default = builtins.toFile "config.json" (builtins.toJSON ({
          NetworkName = cfg.environmentName;
          GenesisHash = "";
          inherit (cfg.environment.nodeConfig) RequiresNetworkMagic;
        } // cfg.logConfig));
      };
      environment = lib.mkOption {
        type = lib.types.attrs;
        default = pkgs.iohkNix.cardanoLib.environments.${cfg.environmentName};
      };
      logConfig = lib.mkOption {
        type = lib.types.attrs;
        default = pkgs.iohkNix.cardanoLib.defaultExplorerLogConfig;
      };
      environmentName = lib.mkOption {
        type = lib.types.str;
        description = "environment name";
      };
      socketPath = lib.mkOption {
        type = lib.types.path;
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "smash";
        description = "the user to run as";
      };
      postgres = {
        pgpass = lib.mkOption {
          type = lib.types.path;
          default = builtins.toFile "pgpass" "${cfg.postgres.socketdir}:${toString cfg.postgres.port}:${cfg.postgres.database}:${cfg.postgres.user}:*";
        };
        socketdir = lib.mkOption {
          type = lib.types.str;
          default = "/run/postgresql";
          description = "the path to the postgresql socket";
        };
        port = lib.mkOption {
          type = lib.types.int;
          default = config.services.postgresql.port;
          description = "the postgresql port";
        };
        database = lib.mkOption {
          type = lib.types.str;
          default = cfg.postgres.user;
          description = "the postgresql database to use";
        };
        user = lib.mkOption {
          type = lib.types.str;
          default = cfg.user;
          description = "the postgresql user to use";
        };
      };
    };
  };
  config = lib.mkIf cfg.enable {
    services.smash.script = pkgs.writeShellScript "smash" ''
      set -euo pipefail

      cp ${cfg.postgres.pgpass} $RUNTIME_DIRECTORY/pgpass
      chmod 0600 $RUNTIME_DIRECTORY/pgpass
      export SMASHPGPASSFILE=$RUNTIME_DIRECTORY/pgpass

      ${cfg.package}/bin/smash-exe run-migrations --mdir ${../../schema}
      exec ${cfg.package}/bin/smash-exe run-app-with-db-sync \
        --config ${cfg.configFile} \
        --genesis-file ${cfg.environment.genesisFile} \
        --socket-path ${cfg.socketPath} \
        --schema-dir ${../../schema}
    '';
    environment.systemPackages = [ cfg.package config.services.postgresql.package ];
    systemd.services.smash = {
      path = [ cfg.package config.services.postgresql.package pkgs.netcat ];
      preStart = ''
        for x in {1..10}; do
          nc -z localhost ${toString config.services.smash.postgres.port} && break
          echo loop $x: waiting for postgresql 2 sec...
          sleep 2
        done
        sleep 1
      '';
      serviceConfig = {
        ExecStart = config.services.smash.script;
        DynamicUser = true;
        RuntimeDirectory = "smash";
      };

      wantedBy = [ "multi-user.target" ];
      after = [ "postgres.service" "cardano-node.service" ];
      requires = [ "postgresql.service" ];
    };
  };
}