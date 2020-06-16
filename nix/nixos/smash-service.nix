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
        default = (import ../. {}).smashHaskellPackages.smash.components.exes.smash-exe;
      };
    };
  };
  config = lib.mkIf cfg.enable {
    services.smash.script = pkgs.writeShellScript "smash" ''
      set -euo pipefail

      cp ${config.services.cardano-db-sync.pgpass} $RUNTIME_DIRECTORY/pgpass
      chmod 0600 $RUNTIME_DIRECTORY/pgpass
      export PGPASSFILE=$RUNTIME_DIRECTORY/pgpass

      ${cfg.package}/bin/smash-exe run-migrations --mdir ${../../schema}
      exec ${cfg.package}/bin/smash-exe run-app
    '';
    environment.systemPackages = [ cfg.package config.services.postgresql.package ];
    systemd.services.smash = {
      path = [ cfg.package config.services.postgresql.package pkgs.netcat ];
      preStart = ''
        for x in {1..10}; do
          nc -z localhost ${toString config.services.cardano-db-sync.postgres.port} && break
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
      after = [ "postgres.service" "cardano-db-sync.service" ];
      requires = [ "postgresql.service" ];
    };
  };
}
