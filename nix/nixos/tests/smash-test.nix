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
        environmentName = "shelley_testnet";
        inherit (config.services.cardano-node) socketPath;
      };
      services.cardano-node = {
        enable = true;
        environment = "shelley_testnet";
      };
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
    startAll
    $machine->waitForUnit("postgresql.service");
    $machine->waitForUnit("cardano-node.service");
  '';

}
