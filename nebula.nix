# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, lib, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration/nebula.nix
    ];

  # Needed by RPi firmware
  nixpkgs.config.allowUnfree = true;

  boot.loader.grub.enable = false;
  boot.loader.raspberryPi = {
    enable = true;
    version = 3;
    uboot.enable = true;
  };

  boot.consoleLogLevel = lib.mkDefault 7;
  # https://github.com/NixOS/nixpkgs/issues/82455
  boot.kernelPackages = pkgs.linuxPackages_5_4;

  # The serial ports listed here are:
  # - ttyS0: for Tegra (Jetson TX1)
  # - ttyAMA0: for QEMU's -machine virt
  # Also increase the amount of CMA to ensure the virtual console on the RPi3 works.
  boot.kernelParams = ["cma=32M" "console=ttyS0,115200n8" "console=ttyAMA0,115200n8" "console=tty0"];

  networking.hostName = "nebula"; # Define your hostname.
  networking.interfaces.eth0 = {
    macAddress = "B8:27:EB:96:A8:31";
  };

  environment.noXlibs = true;
  services.udisks2.enable = !config.environment.noXlibs; # Pulls in X11

  environment.systemPackages = with pkgs; [
    file
    git
    htop
    silver-searcher
    tmux
    vim
  ];

  # Set your time zone.
  time.timeZone = "Asia/Singapore";

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    permitRootLogin = "no";
    passwordAuthentication = false;
    challengeResponseAuthentication = false;
    allowSFTP = false;
  };

  # Open ports in the firewall.
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [
    # DNS
    53
    # HTTP(S)
    80
    443
  ];
  networking.firewall.allowedUDPPorts = [
    # DNS
    53
  ];
  networking.hosts = {
    "192.168.1.148" = ["thanos" "binarycache.thanos" "restic.thanos" "pihole.thanos"];
    "192.168.1.20" = ["nebula" "pihole.nebula"];
  };

  #
  # Services
  #

  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.pihole = {
    image = "pihole/pihole:latest";
    ports = [
      "192.168.1.20:53:53/tcp"
      "192.168.1.20:53:53/udp"
      "3080:80"
      "30443:443"
    ];
    volumes = [
      "/var/lib/pihole/:/etc/pihole/"
      "/var/lib/dnsmasq.d:/etc/dnsmasq.d/"
    ];
    extraOptions = [
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

  services.nginx = {
    enable = true;
    appendHttpConfig = ''
      server_names_hash_bucket_size 64;
    '';
    virtualHosts = {
      "pihole.nebula" = {
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
    };
  };

  #
  # Users
  # 

  security.sudo.enable = true;

  users.mutableUsers = false;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.j = {
    isNormalUser = true;
    home = "/home/j";
    shell = pkgs.zsh;
    hashedPassword = "$6$22Tois4OjFC$y3kfcuR7BBHVj8LnZNIfLyNhQOdVZkkTseXCNbiA95WS2JSXv4Zynmy8Ie9nCxNokgSL8cuO1Le0m4VHuzXXI.";
    extraGroups = [ "wheel" "bluetooth" "vboxusers" ];
    subUidRanges = [{ startUid = 100000; count = 65536; }];
    subGidRanges = [{ startGid = 100000; count = 65536; }];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDFErWB61gZadEEFteZYWZm8QRwabpl4kDHXsm0/rsLqoyWJN5Y4zF4kowSGyf92LfJu9zNBs2viuT3vmsLfg6r4wkbVyujpEo3JLuV79r9K8LcM32wA52MvQYATEzxuamZPZCBT9fI/2M6bC9lz67RQ5IoENfjZVCstOegSmODmOvGUs6JjrB40slB+4YXCVFypYq3uTyejaBMtKdu1S4TWUP8WRy8cWYmCt1+a6ACV2yJcwnhSoU2+QKt14R4XZ4QBSk4hFgiw64Bb3WVQlfQjz3qA4j5Tc8P3PESKJcKW/+AsavN1I2FzdiX1CGo2OL7p9TcZjftoi5gpbmzRX05 j@riza"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQChHW69/lghzz2b6T8hj6cShYGGDNA7g+HhS+P7JAWT43NiCvM+0S3xYr0sY/MNBqTHIV/5e2prP4uaCq7uyNT/5s8LLm6at8dhrKN1RZWQpHD9FID5sgw4yv8HANyVpt1+zY6PoqmhAb+Bj/g/H3Ijb+AAWbvWKxUMoChC9nWd5G+ogPpPQmElg/aGxjAL0oSuwGHEO1wNvV4/ddKLEWiLNF8Xdc0s4QkQnJZhyZMa+oaerI4wF7GqsVzsYg4ppK6YbZt5rv41XCqKp889b2JZphRVlN7LvJxX11ttctxFvhSlqa+C/7QvoFiOo5wJxZrwH3P1rMRfIWwzYas/sWlx jophish@cardassia.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBML4JuxphjzZ/gKVLRAunKfTuFT6VVr6DfXduvsiHz j@orion"
    ];
  };

  # nixpkgs stuff
  nix.nixPath =
    [ "nixpkgs=/etc/nixpkgs" "nixos-config=/etc/nixos/configuration.nix" ];

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "18.09"; # Did you read the comment?
}
