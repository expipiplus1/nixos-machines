{ config, pkgs, lib, ... }:

{
  imports = [ ./nebula.nix ];

  networking.hostName = lib.mkForce "gamora";
  networking.interfaces.eth0 = {
    macAddress = lib.mkForce "B8:27:EB:A8:31:67";
  };
  networking.interfaces.wlan0 = {
    macAddress = "B8:27:EB:FD:64:32";
  };

  # The global useDHCP flag is deprecated, therefore explicitly set to false here.
  # Per-interface useDHCP will be mandatory in the future, so this generated config
  # replicates the default behaviour.
  networking.useDHCP = false;
  networking.interfaces.eth0.useDHCP = true;
  networking.interfaces.wlan0.useDHCP = true;

  networking.wireless.enable = false;
  networking.wireless.extraConfig = ''
    ctrl_interface=/run/wpa_supplicant
    ctrl_interface_group=wheel
  '';
  # networking.wireless.networks.Galandriel.pskRaw = "";
}
