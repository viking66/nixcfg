{ config, pkgs, lib, ... }:

{
  networking = {
    computerName = "vesal-jason";
    hostName = "vesal-jason";
  };

  ids.gids.nixbld = 350;
}
