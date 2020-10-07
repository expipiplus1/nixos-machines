#
# From https://jarmac.org/posts/time-machine.html
#
{ config, pkgs, ... }:
let
  timeMachineDir = "/data/share/Emma";
  user = "emma";
in {
  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };
  services.netatalk = {
    enable = true;
    extraConfig = ''
      mimic model = TimeCapsule6,106
      log level = default:warn
      log file = /var/log/afpd.log
      hosts allow = 192.168.1.0/24
      set password = yes
    [${user}'s share]
      path = ${timeMachineDir}
      valid users = ${user}
    [linux isos]
      path = /data/share/linux-isos
      valid users = ${user}
      read only = yes
    '';
  };
  systemd.services.macUserSetup = {
    description = "idempotent directory setup for ${user}'s time machine";
    requiredBy = [ "netatalk.service" ];
    script = '' mkdir -p ${timeMachineDir}
                chown --recursive ${user}:users ${timeMachineDir}
                chmod --recursive 0750 ${timeMachineDir} '';
  };
  networking.firewall.allowedTCPPorts = [ 548 636 ];
}