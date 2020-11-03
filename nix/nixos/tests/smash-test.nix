{ pkgs, ... }:
with pkgs; with commonLib;
{
  name = "smash-test";
  nodes = {
    machine = { config, ... }: {
      nixpkgs.pkgs = pkgs;
      environment = {
        systemPackages = with pkgs; [ curl jq ];
        variables = {
          SMASHPGPASSFILE = config.services.smash.postgres.pgpass;
        };
      };
      imports = [
        ../smash-service.nix
        (sources.cardano-node + "/nix/nixos")
      ];
      services.smash = {
        enable = true;
        environmentName = "mainnet";
        smashPkgs = pkgs;
        inherit (config.services.cardano-node) socketPath;
      };
      systemd.services.smash.serviceConfig = {
        # Put cardano-db-sync in "cardano-node" group so that it can write socket file:
        SupplementaryGroups = "cardano-node";
      };
      services.cardano-node = {
        enable = true;
        environment = "mainnet";
        package = smashHaskellPackages.cardano-node.components.exes.cardano-node;
	      topology = cardanoLib.mkEdgeTopology {
          port = 3001;
          edgeNodes = [ "127.0.0.1" ];
        };
      };
      systemd.services.cardano-node.serviceConfig.Restart = lib.mkForce "no";
      services.postgresql = {
        enable = true;
        package = postgresql_12;
        enableTCPIP = false;
        ensureDatabases = [ "${config.services.smash.postgres.database}" ];
        ensureUsers = [
          {
            name = "${config.services.smash.postgres.user}";
            ensurePermissions = {
              "DATABASE ${config.services.smash.postgres.database}" = "ALL PRIVILEGES";
            };
          }
        ];
        identMap = ''
          smash-users root ${config.services.smash.postgres.user}
          smash-users ${config.services.smash.user} ${config.services.smash.postgres.user}
          smash-users postgres postgres
        '';
        authentication = ''
          local all all ident map=smash-users
        '';
      };
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("cardano-node.service")
    machine.wait_for_open_port(3001)
    machine.wait_for_unit("smash.service")
    machine.wait_for_open_port(3100)
  '';

}
