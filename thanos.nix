{ config, pkgs, ... }:

let
  crossPkgs = import pkgs.path {
    crossSystem = { system="armv7l-linux"; };
    system="x86_64-linux";
  };
in

{
  imports =
    [ ./hardware-configuration/thanos.nix
      ./helios4-nix/helios4.nix
    ];

  ########################################
  # Boot
  ########################################

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  ########################################
  # Services
  ########################################

  services.slimserver = {
    enable = true;
  };

  ########################################
  # Networking
  ########################################

  networking.hostName = "thanos";
  networking.interfaces.eth0 = {
    macAddress = "5A:B5:1A:A6:79:5E";
  };
  networking.dhcpcd.extraConfig = ''
    # define static profile
    profile static_eth0
    static ip_address=192.168.1.19/24
    static routers=192.168.1.1
    static domain_name_servers=192.168.1.148 192.168.1.20
    
    # fallback to static profile on eth0
    interface eth0
    fallback static_eth0
  '';

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      # DNS
      53
      # HTTP(S)
      80
      443
      # Slimserver
      9000
      3483
      # Samba
      139
      445
      # Socks
      12345
    ];
    allowedUDPPorts = [
      # Slimserver
      3483
      # Samba
      137 138
      # Mosh
      60000
      60001
    ];
  };

  services.openssh = {
    enable = true;
    permitRootLogin = "no";
    passwordAuthentication = false;
    challengeResponseAuthentication = false;
    allowSFTP = false;
    extraConfig = ''
      Subsystem sftp internal-sftp
      Match user sshfs
        ForceCommand internal-sftp
        ChrootDirectory /data/share/linux-isos
        AllowTcpForwarding no
    '';
  };

  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.pihole = {
    image = "pihole/pihole:latest";
    ports = [
      "192.168.1.148:53:53/tcp"
      "192.168.1.148:53:53/udp"
      "3080:80"
      "30443:443"
    ];
    volumes = [
      "/var/lib/pihole/:/etc/pihole/"
      "/var/lib/dnsmasq/.d:/etc/dnsmasq.d/"
    ];
    environment = {
      ServerIP = "192.168.1.148";
    };
    extraOptions = [
      "--cap-add=NET_ADMIN"
      "--dns=127.0.0.1"
      "--dns=1.1.1.1"
    ];
    workdir = "/var/lib/pihole/";
  };

  services.fail2ban = {
    enable = true;
    jails = {
      nginx-botsearch = ''
        filter   = nginx-botsearch
        action = iptables-multiport[name=NGINXBOT, port=http,https, protocol=tcp]
      '';
      nginx-http-auth = ''
        filter   = nginx-http-auth
        action = iptables-multiport[name=NGINXAUTH, port=http,https, protocol=tcp]
      '';
    };
  };

  security.acme = {
    email = "acme@sub.monoid.al";
    acceptTerms = true;
  };

  services.nginx = {
    enable = true;
    appendHttpConfig = ''
      server_names_hash_bucket_size 64;
    '';
    virtualHosts = {
      "home.monoid.al" = {
        forceSSL = true;
        enableACME = true;
        default = true;
        locations = {
          "/" = {
            root = "/var/www";
            extraConfig = ''
              index index.html;
              autoindex on;
            '';
          };
        };
      };
      "binarycache.thanos" = {
        locations."/" = {
          proxyPass = "http://localhost:${toString config.services.nix-serve.port}";
          extraConfig = ''
            allow 192.168.1.0/24;
            allow 127.0.0.1;
            deny all;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          '';
        };
      };
      "pihole.thanos" = {
        locations."/" = {
          proxyPass = "http://localhost:3080";
          extraConfig = ''
            allow 192.168.1.0/24;
            allow 127.0.0.1;
            deny all;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          '';
        };
      };
      "restic.thanos" = {
        locations."/" = {
          proxyPass = "http://localhost:8000";
          extraConfig = ''
            allow 192.168.1.0/24;
            allow 127.0.0.1;
            deny all;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            # Allow any size file to be uploaded.
            client_max_body_size 0;
          '';
        };
      };
      "binarycache.home.monoid.al" = {
        forceSSL = true;
        enableACME = true;
        extraConfig = ''
          # To allow special characters in headers
          ignore_invalid_headers off;
          # Allow any size file to be uploaded.
          client_max_body_size 0;
          # To disable buffering
          proxy_buffering off;
        '';
        locations = {
          "/" = {
            proxyPass = "http://localhost:${toString config.services.nix-serve.port}";
            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            '';
          };
        };
      };
      "restic.home.monoid.al" = {
        forceSSL = true;
        enableACME = true;
        extraConfig = ''
          # To allow special characters in headers
          ignore_invalid_headers off;
          # Allow any size file to be uploaded.
          client_max_body_size 0;
          # To disable buffering
          proxy_buffering off;
        '';
        locations = {
          "/" = {
            proxyPass = "http://localhost:8000";
            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            '';
          };
        };
      };
    };
  };

  services.restic.server = {
    enable = true;
    dataDir = "/data/restic";
    privateRepos = true;
    appendOnly = true;
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /export               192.168.1.0/24(rw,fsid=0,no_subtree_check)
      /export/share         192.168.1.0/24(rw,nohide,insecure,no_subtree_check)
    '';
    statdPort = 4000;
    lockdPort = 4001;
    mountdPort = 4002;
  };
  fileSystems."/export/share" = {
    device = "/data/share";
    options = [ "bind" ];
  };

  services.samba = {
    enable = true;
    syncPasswordsByPam = true;	
    extraConfig = ''
      map to guest = Bad User
    '';
    shares = {
      share = {
        browseable = "yes";
        comment = "Thanos share";
        "guest ok" = "yes";
        path = "/data/share";
        writable = "yes";
        "force user" = "root";
        "create mask" = "0644";
        "directory mask" = "0755";
      };
    };
  };

  services.nullmailer = {
    enable = true;
    remotesFile = "/etc/nullmailer-credentials";
    config.defaulthost = "home.monoid.al";
  };

  ########################################
  # Misc
  ########################################

  time.timeZone = "Asia/Singapore";

  environment.noXlibs = true;
  environment.systemPackages = with pkgs; [
    file
    git
    htop
    silver-searcher
    tmux
    vim
    gcc
    lm_sensors
    hddtemp
    restic
  ];

  ########################################
  # Users
  ########################################

  security.sudo.enable = true;

  users.mutableUsers = false;

  users.users.j = {
    isNormalUser = true;
    home = "/home/j";
    description = "Joe Hermaszewski";
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$22Tois4OjFC$y3kfcuR7BBHVj8LnZNIfLyNhQOdVZkkTseXCNbiA95WS2JSXv4Zynmy8Ie9nCxNokgSL8cuO1Le0m4VHuzXXI.";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDFErWB61gZadEEFteZYWZm8QRwabpl4kDHXsm0/rsLqoyWJN5Y4zF4kowSGyf92LfJu9zNBs2viuT3vmsLfg6r4wkbVyujpEo3JLuV79r9K8LcM32wA52MvQYATEzxuamZPZCBT9fI/2M6bC9lz67RQ5IoENfjZVCstOegSmODmOvGUs6JjrB40slB+4YXCVFypYq3uTyejaBMtKdu1S4TWUP8WRy8cWYmCt1+a6ACV2yJcwnhSoU2+QKt14R4XZ4QBSk4hFgiw64Bb3WVQlfQjz3qA4j5Tc8P3PESKJcKW/+AsavN1I2FzdiX1CGo2OL7p9TcZjftoi5gpbmzRX05 j@riza"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQChHW69/lghzz2b6T8hj6cShYGGDNA7g+HhS+P7JAWT43NiCvM+0S3xYr0sY/MNBqTHIV/5e2prP4uaCq7uyNT/5s8LLm6at8dhrKN1RZWQpHD9FID5sgw4yv8HANyVpt1+zY6PoqmhAb+Bj/g/H3Ijb+AAWbvWKxUMoChC9nWd5G+ogPpPQmElg/aGxjAL0oSuwGHEO1wNvV4/ddKLEWiLNF8Xdc0s4QkQnJZhyZMa+oaerI4wF7GqsVzsYg4ppK6YbZt5rv41XCqKp889b2JZphRVlN7LvJxX11ttctxFvhSlqa+C/7QvoFiOo5wJxZrwH3P1rMRfIWwzYas/sWlx jophish@cardassia.local"
    ];
  };


  ########################################
  # Nix
  ########################################

  nix.trustedUsers = [ "root" "@wheel" ];

  nixpkgs.config.allowUnfree = true;
  nixpkgs.overlays = [
    (self: super: {
      libndctl = crossPkgs.libndctl;
      restic = crossPkgs.restic;
      rng-tools = super.rng-tools.override { withPkcs11 = false; };
      mesa_noglu = super.mesa_noglu.override {
        llvmPackages = self.llvmPackages_6;
      };
      # llvmPackages_6 = crossPkgs.llvmPackages_6;
      # llvmPackages_7 = crossPkgs.llvmPackages_7;
    })
  ];

  nix.nixPath = [
    "nixpkgs=/etc/nixpkgs"
    "nixos-config=/etc/nixos/configuration.nix"
  ];
  nix.binaryCaches = [
    # "http://nixos-arm.dezgeg.me/channel"
    "https://cache.nixos.org/"
  ];
  nix.binaryCachePublicKeys = [
    # "nixos-arm.dezgeg.me-1:xBaUKS3n17BZPKeyxL4JfbTqECsT+ysbDJz29kLFRW0=%"
    "hydra.nixos.org-1:CNHJZBh9K4tP3EKF6FkkgeVYsS3ohTl+oS0Qa8bezVs="
  ];
  nix.buildMachines = [ {
    hostName = "riza";
    system = "x86_64-linux";
    maxJobs = 8;
    speedFactor = 2;
    supportedFeatures = ["big-parallel"]; # To get it to build linux
    mandatoryFeatures = [];
  }] ;
  nix.distributedBuilds = true;

  services.nix-serve = {
    enable = true;
    secretKeyFile = "/var/cache-priv-key.pem";
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "18.09"; # Did you read the comment?
}
