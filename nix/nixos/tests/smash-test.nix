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
    $machine->waitForUnit("smash.service");
    $machine->waitForOpenPort(3100);
    $machine->succeed("smash-exe insert-pool --metadata ${../../../test_pool.json} --poolhash \"cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f\"");
    $machine->succeed("curl -s -i -H \"Accept: application/json\" http://localhost:3100/api/v1/metadata/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f | systemd-cat --identifier=curl-smash");
    $machine->succeed("curl -s -H \"Accept: application/json\" http://localhost:3100/api/v1/metadata/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f | jq | systemd-cat --identifier=jq-smash");
  '';

}
