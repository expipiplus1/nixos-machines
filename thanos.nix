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
    ];

  ########################################
  # Boot
  ########################################

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Build the kernel on on x86-64
  # A patch is included to get both PWM fans working
  boot.kernelPackages = with crossPkgs;
    let linux_helios4 = linux_4_19.override {
          kernelPatches = [
            kernelPatches.bridge_stp_helper
            kernelPatches.modinst_arg_list_too_long
            kernelPatches.raspberry_pi_wifi_fix
            {name = "helios4-fan"; patch = ./patches/helios4-fan.patch;}
          ];
          defconfig = "mvebu_v7_defconfig";
          structuredExtraConfig = { DRM="n"; };
        };
    in  recurseIntoAttrs (linuxPackagesFor linux_helios4);

  ########################################
  # Hardware
  ########################################

  systemd.services.fancontrol = {
    description = "fancontrol daemon";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
      ExecStart =
        let conf = pkgs.writeText "fancontrol.conf" ''
          # Helios4 PWM Fan Control Configuration
          # Temp source : /dev/thermal-board
          INTERVAL=10
          FCTEMPS=/dev/fan-j10/pwm1=/dev/thermal-board/temp1_input /dev/fan-j17/pwm1=/dev/thermal-board/temp1_input
          MINTEMP=/dev/fan-j10/pwm1=45  /dev/fan-j17/pwm1=45
          MAXTEMP=/dev/fan-j10/pwm1=70  /dev/fan-j17/pwm1=70
          MINSTART=/dev/fan-j10/pwm1=20 /dev/fan-j17/pwm1=20
          MINSTOP=/dev/fan-j10/pwm1=29  /dev/fan-j17/pwm1=29
          MINPWM=0
        '';
        in "${pkgs.lm_sensors}/sbin/fancontrol ${conf}";
    };
  };

  services.udev.extraRules = ''
    # Helios4 persistent hwmon

    ACTION=="remove", GOTO="helios4_hwmon_end"

    #
    KERNELS=="j10-pwm", SUBSYSTEMS=="platform", ENV{_HELIOS4_FAN_}="j10", ENV{_IS_HELIOS4_FAN_}="1", ENV{IS_HELIOS4_HWMON}="1"
    KERNELS=="j17-pwm", SUBSYSTEMS=="platform", ENV{_HELIOS4_FAN_}="j17", ENV{_IS_HELIOS4_FAN_}="1", ENV{IS_HELIOS4_HWMON}="1"
    KERNELS=="0-004c", SUBSYSTEMS=="i2c", DRIVERS=="lm75", ENV{IS_HELIOS4_HWMON}="1"

    SUBSYSTEM!="hwmon", GOTO="helios4_hwmon_end"

    ENV{HWMON_PATH}="/sys%p"
    #
    ATTR{name}=="f1072004mdiomii00", ENV{IS_HELIOS4_HWMON}="1", ENV{HELIOS4_SYMLINK}="/dev/thermal-eth"
    ATTR{name}=="armada_thermal", ENV{IS_HELIOS4_HWMON}="1", ENV{HELIOS4_SYMLINK}="/dev/thermal-cpu"
    #
    ENV{IS_HELIOS4_HWMON}=="1", ATTR{name}=="lm75", ENV{HELIOS4_SYMLINK}="/dev/thermal-board"
    ENV{_IS_HELIOS4_FAN_}=="1", ENV{HELIOS4_SYMLINK}="/dev/fan-$env{_HELIOS4_FAN_}"

    #
    ENV{IS_HELIOS4_HWMON}=="1", RUN+="${pkgs.coreutils}/bin/ln -sf $env{HWMON_PATH} $env{HELIOS4_SYMLINK}"

    LABEL="helios4_hwmon_end"
  '';

  ########################################
  # Services
  ########################################

  services.minio = {
    enable = true;
    browser = true;
    dataDir = "/data/minio";
  };

  services.slimserver = {
    enable = true;
  };

  ########################################
  # Networking
  ########################################

  networking.hostName = "thanos";
  networking.interfaces.eth0.macAddress = "5A:B5:1A:A6:79:5E";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      # HTTP(S)
      80
      443
      # NFS
      111
      4000
      4001
      4002
      2049
    ];
    allowedUDPPorts = [
      # NFS
      111
      4000
      4001
      4002
      2049
    ];
  };

  services.openssh = {
    enable = true;
    permitRootLogin = "no";
    passwordAuthentication = false;
  };

  services.fail2ban = {
    enable = true;
  };

  services.nginx = {
    enable = true;
    virtualHosts = {
      "home.monoid.al" = {
        forceSSL = true;
        enableACME = true;
        locations = {
          "/" = {
            root = "/var/www";
          };
        };
      };
      "minio.home.monoid.al" = {
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
              proxyPass = "http://localhost:9000";
              extraConfig = ''
                proxy_set_header Host $http_host;
                # health_check uri=/minio/health/ready;
              '';
            };
          };
       };
    };
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

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "18.09"; # Did you read the comment?
}
