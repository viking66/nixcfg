{ config, pkgs, lib, ... }:

{
  networking = {
    computerName = "havoc";
    hostName = "havoc";
  };

  ids.gids.nixbld = 30000;
}
