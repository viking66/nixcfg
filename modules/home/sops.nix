{ config, pkgs, lib, ... }:

{
  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/nixcfg/key.txt";
  };
}
