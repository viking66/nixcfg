{ config, pkgs, lib, inputs, flakeRoot, ... }:

{
  imports = [
    inputs.sops-nix.homeManagerModules.sops
    (flakeRoot + "/home-modules/common.nix")
    (flakeRoot + "/home-modules/sops.nix")
  ];
}
