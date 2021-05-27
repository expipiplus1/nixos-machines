{ pkgs, config, lib, ... }:
let
  synapse-port = 8008;

in {
  imports = [
    ./signald-module.nix
    ./mautrix-signal-module.nix
  ];

  services.signald = {
    enable = true;
  };

  services.mautrix-signal = {
    enable = true;
    environmentFile = /etc/secrets/mautrix-signal.env;
    settings = {
      homeserver = {
        address = "http://localhost:${builtins.toString synapse-port}";
        domain = config.networking.domain;
      };
      bridge = {
        public_portals = false;
        federate_rooms = false;
        permissions = {
          "@joe:monoid.al" = "admin";
        };
        contact_list_names = "allow";
        autocreate_contact_portal = false;
        autocreate_group_portal = true;
      };
    };
  };
}
