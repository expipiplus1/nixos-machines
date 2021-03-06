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
      ./afp.nix
      ./minio.nix
      ./quoth.nix
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
    enable = false;
  };

  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/" ];
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
      # Samba
      139
      445
      # Socks
      12345
    ];
    allowedUDPPorts = [
      # DNS
      53
      # Slimserver
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

  # From https://github.com/NixOS/nixpkgs/issues/61617#issuecomment-623934193
  services.dnsmasq.enable = true;
  services.dnsmasq.extraConfig = ''
    domain-needed
    bogus-priv
    no-resolv

    server=208.67.220.220
    server=8.8.4.4

    listen-address=::1,127.0.0.1,192.168.1.148
    bind-interfaces

    cache-size=10000
    log-queries
    log-facility=/tmp/ad-block.log
    local-ttl=300

    conf-file=/etc/assets/hosts-blocklists/domains.txt
    addn-hosts=/etc/assets/hosts-blocklists/hostnames.txt
  '';

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

  # fix error in service log
  #
  # thanos smbd[18060]: [2020/07/10 13:24:48.294792,  0] ../../source3/lib/sysquotas.c:565(sys_get_quota)
  # thanos smbd[18060]:   sys_path_to_bdev() failed for path [.]!
  security.pam.services.samba-smbd.limits = [
    { domain = "*"; type = "soft"; item = "nofile"; value = 16384; }
    { domain = "*"; type = "hard"; item = "nofile"; value = 32768; }
  ];
  services.samba = {
    enable = true;
    extraConfig = ''
      map to guest = Bad User
      get quota command = ${pkgs.writeScript "smb-quota.sh" ''
        #!${pkgs.bash}/bin/bash
        echo "0 0 0 0 0 0 0"
      ''}
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

  systemd.services.serialLog = {
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    description = "log serial on /dev/ttyUSB0";
    path = with pkgs; [ bash coreutils tio expect ];
    serviceConfig = {
      Type = "simple";
      LogsDirectory = "serial";
      ExecStart = pkgs.writeShellScript "serial log" ''
        logDir=$LOGS_DIRECTORY
        logFile=$logDir/$(date --iso-8601=seconds)
        tty=/dev/ttyUSB0
        sleep infinity | unbuffer -p tio $tty >> "$logFile"
      '';
      Restart = "always";
    };
  };

  ########################################
  # Misc
  ########################################

  time.timeZone = "Asia/Singapore";

  environment.noXlibs = true;
  services.udisks2.enable = !config.environment.noXlibs; # Pulls in X11
  nixpkgs.config.cairo.gl = false;

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

  # No need to bring in a JS interpreter for the system
  security.polkit.enable = false;

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
    shell = pkgs.zsh;
    hashedPassword = "$6$22Tois4OjFC$y3kfcuR7BBHVj8LnZNIfLyNhQOdVZkkTseXCNbiA95WS2JSXv4Zynmy8Ie9nCxNokgSL8cuO1Le0m4VHuzXXI.";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDFErWB61gZadEEFteZYWZm8QRwabpl4kDHXsm0/rsLqoyWJN5Y4zF4kowSGyf92LfJu9zNBs2viuT3vmsLfg6r4wkbVyujpEo3JLuV79r9K8LcM32wA52MvQYATEzxuamZPZCBT9fI/2M6bC9lz67RQ5IoENfjZVCstOegSmODmOvGUs6JjrB40slB+4YXCVFypYq3uTyejaBMtKdu1S4TWUP8WRy8cWYmCt1+a6ACV2yJcwnhSoU2+QKt14R4XZ4QBSk4hFgiw64Bb3WVQlfQjz3qA4j5Tc8P3PESKJcKW/+AsavN1I2FzdiX1CGo2OL7p9TcZjftoi5gpbmzRX05 j@riza"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQChHW69/lghzz2b6T8hj6cShYGGDNA7g+HhS+P7JAWT43NiCvM+0S3xYr0sY/MNBqTHIV/5e2prP4uaCq7uyNT/5s8LLm6at8dhrKN1RZWQpHD9FID5sgw4yv8HANyVpt1+zY6PoqmhAb+Bj/g/H3Ijb+AAWbvWKxUMoChC9nWd5G+ogPpPQmElg/aGxjAL0oSuwGHEO1wNvV4/ddKLEWiLNF8Xdc0s4QkQnJZhyZMa+oaerI4wF7GqsVzsYg4ppK6YbZt5rv41XCqKp889b2JZphRVlN7LvJxX11ttctxFvhSlqa+C/7QvoFiOo5wJxZrwH3P1rMRfIWwzYas/sWlx jophish@cardassia.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBML4JuxphjzZ/gKVLRAunKfTuFT6VVr6DfXduvsiHz j@orion"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBFTU5LRUEQrVz94VSBbxFzk5AzKp1CwCVBr2tO9cIEq j@nebula"
    ];
  };

  users.users.emma = {
    name = "emma";
    group = "users";
    hashedPassword = "$6$R71AjWfi.7dWVvA$sSR4eJ0VBPDJ53IvEFflKue5Eitgr8DfvV05cT.3YW0177skQX/XJOT1KQAHHO8wrYh6qWNmXHQX1vI94L504.";
  };

  users.users.sshfs = {
    isNormalUser = false;
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCkqMncj+6l1p4BIFpJD7f1oddOi9hCTyUcj2DDKEYsJD4q9lObdlPUpTkI/1C95yC0EtTC7Gv1R4Z5i9dYtiKYDHSkD+GjxSAnmrG37vX7bYgqYaSP4qcqbFIAUfokXHaAT22cjCxatZuZjkA8jJbAVNPX8k6f+MwCbjGWsFGRMBuacVwA3/dx1d2eYGy5rVPAN7bnTh9HWIPKiSNm2/1WafzkmE0F+wXJ4e+i3eNNcyWxufCH5+sq/V2471PX0spco/2vg5SvnoQOL60H2N6Lxto804mXNzJPlNPPcbE6OrQ/wMkAE6ESh/X4gpq8qILPJHMIhxvZ4Nggi0YAoovn jophish@sen"
    ];
  };

  users.extraUsers.nix = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBMrsS7pSYHZX/6JN2+ndNK/gy7r2r2Jpv7PxfpjJeof root@thanos"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHEziWh0o8uJ0pBQDNAdSWJF5ZFO3Wo0akf0RvcvXGHR root@nebula"
    ];
    useDefaultShell = true;
  };

  ########################################
  # Nix
  ########################################

  nix.trustedUsers = [ "root" "@wheel" "nix" ];

  nixpkgs.config.allowUnfree = true;
  nixpkgs.overlays = [
    (self: super: {
      rng-tools = super.rng-tools.override {withPkcs11 = false;};
    })
  ];

  nix.binaryCaches = [
    # "http://nixos-arm.dezgeg.me/channel"
    "https://cache.nixos.org/"
    "s3://nix-cache?region=ap-southeast-1&scheme=http&endpoint=localhost:9002"
  ];
  nix.binaryCachePublicKeys = [
    # "nixos-arm.dezgeg.me-1:xBaUKS3n17BZPKeyxL4JfbTqECsT+ysbDJz29kLFRW0=%"
    "hydra.nixos.org-1:CNHJZBh9K4tP3EKF6FkkgeVYsS3ohTl+oS0Qa8bezVs="
    "orion:s0C06f1M46DCpHUUP2r8iIrhfytkCbXWltMeMMa4jbw=%"
    "expipiplus1/update-nix-fetchgit:Z33K0KEImsos+kVTFvZxfLxaBi+D1jEeB6cX0uCo7B0="
  ];
  networking.hosts = {
    "192.168.1.77" = [ "riza" ];
    "192.168.1.121" = [ "orion" ];
  };
  nix.buildMachines = [ {
    hostName = "riza";
    system = "x86_64-linux";
    maxJobs = 8;
    speedFactor = 2;
    supportedFeatures = ["big-parallel"]; # To get it to build linux
    mandatoryFeatures = [];
  }
  {
    hostName = "orion";
    sshUser = "nix";
    sshKey = "/root/.ssh/id_buildfarm";
    system = "x86_64-linux";
    maxJobs = 16;
    speedFactor = 4;
    supportedFeatures = ["big-parallel"]; # To get it to build linux
    mandatoryFeatures = [];
  }];
  nix.distributedBuilds = true;

  services.nix-serve = {
    enable = false;
    secretKeyFile = "/var/cache-priv-key.pem";
  };

  system.autoUpgrade = {
    enable = true;
    randomizedDelaySec = "45min";
    flags = ["-k" "-j1" "--option" "build-cores" "1"];
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "18.09"; # Did you read the comment?
}
