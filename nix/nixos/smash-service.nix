{ config, lib, pkgs, ... }:

let
  cfg = config.services.smash;
  self = config.smashInternal.smashPackages;
  smashConfig = cfg.explorerConfig // {
    inherit (cfg.nodeConfig) ByronGenesisFile ShelleyGenesisFile ByronGenesisHash ShelleyGenesisHash Protocol RequiresNetworkMagic;
  };
  configFile = __toFile "config.json" (__toJSON (smashConfig // cfg.logConfig));
in {

  options = {
    smashInternal = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      default = { smashPackages = import ../. {}; };
    };
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
      explorerConfig = lib.mkOption {
        type = lib.types.attrs;
        default = cfg.environment.explorerConfig;
      };
      nodeConfig = lib.mkOption {
        type = lib.types.attrs;
        default = cfg.environment.nodeConfig;
      };
      environment = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = self.iohkNix.cardanoLib.environments.${cfg.environmentName};
      };
      logConfig = lib.mkOption {
        type = lib.types.attrs;
        default = self.iohkNix.cardanoLib.defaultExplorerLogConfig;
      };
      environmentName = lib.mkOption {
        type = lib.types.str;
        description = "environment name";
      };
      socketPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "smash";
        description = "the user to run as";
      };
      postgres = {
        generatePGPASS = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "generate pgpass";
        };

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
          default = 5432;
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
    services.smash.script = let
    in pkgs.writeShellScript "smash" ''
      set -euo pipefail

      RUNTIME_DIRECTORY=''${RUNTIME_DIRECTORY:-$(pwd)}
      ${if (cfg.socketPath == null) then ''if [ -z ''${CARDANO_NODE_SOCKET_PATH:-} ]
      then
        echo "You must set \$CARDANO_NODE_SOCKET_PATH"
        exit 1
      fi'' else "export CARDANO_NODE_SOCKET_PATH=\"${cfg.socketPath}\""}

      ${lib.optionalString cfg.postgres.generatePGPASS ''
      cp ${cfg.postgres.pgpass} /$RUNTIME_DIRECTORY/pgpass
      chmod 0600 $RUNTIME_DIRECTORY/pgpass
      export SMASHPGPASSFILE=/$RUNTIME_DIRECTORY/pgpass
      ''}

      ${cfg.package}/bin/smash-exe run-migrations --mdir ${../../schema}
      exec ${cfg.package}/bin/smash-exe run-app-with-db-sync \
        --config ${configFile} \
        --socket-path "$CARDANO_NODE_SOCKET_PATH" \
        --schema-dir ${../../schema}
    '';
    environment.systemPackages = [ cfg.package config.services.postgresql.package ];
    systemd.services.smash = {
      path = [ cfg.package pkgs.netcat pkgs.postgresql ];
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
