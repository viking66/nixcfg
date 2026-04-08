{ config, pkgs, lib, ... }:

{
  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/key.txt";
  };
}
