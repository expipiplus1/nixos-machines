{ config, pkgs, ... }:

let
  quoth-dir = "/var/quoth";
  quoth-port = 4747;
  quoth = let
    src = builtins.fetchTarball {
      url =
        "https://github.com/expipiplus1/quoth-the-enterprise/archive/a10d3338349cd2acd19c3316663dd66a09a3b6d4.tar.gz"; # master
      sha256 = "0iffm4c1xygkniy3619n3l2c37fw5iwj7lp0p77vlwh4al66ps1w";
    };
    nixpkgsSrc = import "${src}/nixpkgs.nix";
    args = {
      crossSystem = "armv7l-linux";
      system = "x86_64-linux";
    };
  in import "${src}/cross.nix" { pkgs = import nixpkgsSrc args; };

in {
  # Expose this minio cluster with nginx
  services.nginx = {
    commonHttpConfig = ''
      limit_req_zone $binary_remote_addr zone=default:10m rate=120r/m;
    '';
    virtualHosts = {
      "home.monoid.al" = {
        locations = {
          "/quote" = {
            proxyPass = "http://localhost:${toString quoth-port}";
            extraConfig = ''
              auth_basic off;
              limit_req zone=default burst=5;
            '';
          };
        };
      };
    };
  };

  # Largely from https://github.com/NixOS/nixpkgs/issues/89559
  systemd.services.quoth = {
    enable = true;
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "simple";
    environment = { LANG="en_US"; };
    path = [ quoth pkgs.findutils ];
    script = ''
      quoth --port ${toString quoth-port} $(find "${quoth-dir}" -iname '*.htm')
    '';
  };
}
