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
          PGPASSFILE = config.services.cardano-db-sync.pgpass;
        };
      };
      imports = [
        ../smash-service.nix
        (sources.cardano-db-sync + "/nix/nixos")
      ];
      services.cardano-db-sync = {
        enable = true;
        cluster = "ff";
      };
      services.smash = {
        enable = true;
        package = smashHaskellPackages.smash.components.exes.smash-exe;
      };
      services.postgresql = {
        enable = true;
        package = postgresql_12;
        enableTCPIP = false;
        ensureDatabases = [ "${config.services.cardano-db-sync.user}" ];
        ensureUsers = [
          {
            name = "${config.services.cardano-db-sync.user}";
            ensurePermissions = {
              "DATABASE ${config.services.cardano-db-sync.user}" = "ALL PRIVILEGES";
            };
          }
        ];
        identMap = ''
          cdbsync-users root ${config.services.cardano-db-sync.user}
          cdbsync-users smash ${config.services.cardano-db-sync.user}
          cdbsync-users ${config.services.cardano-db-sync.user} ${config.services.cardano-db-sync.user}
          cdbsync-users postgres postgres
        '';
        authentication = ''
          local all all ident map=cdbsync-users
        '';
      };
    };
  };
  testScript = ''
    startAll
    $machine->waitForUnit("postgresql.service");
    $machine->waitForUnit("smash.service");
    $machine->waitForOpenPort(3100);
    $machine->succeed("smash-exe insert-pool --filepath ${../../../test_pool.json} --poolhash \"cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f\"");
    $machine->succeed("curl -s -i -H \"Accept: application/json\" http://localhost:3100/api/v1/metadata/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f | systemd-cat --identifier=curl-smash");
    $machine->succeed("curl -s -H \"Accept: application/json\" http://localhost:3100/api/v1/metadata/cbdfc4f21feb0a414b2b9471fa56b0ebd312825e63db776d68cc3fa0ca1f5a2f | jq | systemd-cat --identifier=jq-smash");
  '';

}
