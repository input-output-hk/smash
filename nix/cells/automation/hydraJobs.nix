{
  cell,
  inputs,
}:

import "${inputs.self}/release.nix" {
  smash = inputs.self;
  supportedSystems = [inputs.nixpkgs.system];
}
