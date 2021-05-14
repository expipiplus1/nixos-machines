# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, lib, pkgs, ... }:

{
  imports = [ # Include the results of the hardware scan.
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

  # Increase the amount of CMA to ensure the virtual console on the RPi3 works.
  boot.kernelParams = [ "cma=32M" "console=ttyS1,115200n8" "console=tty0" ];

  zramSwap = {
    enable = true;
    memoryPercent = 80;
  };

  networking.hostName = "nebula"; # Define your hostname.
  networking.interfaces.eth0 = { macAddress = "B8:27:EB:96:A8:31"; };

  environment.noXlibs = true;
  services.udisks2.enable = !config.environment.noXlibs; # Pulls in X11
  nixpkgs.config.cairo.gl = false;
  security.polkit.enable = false;
  nixpkgs.overlays = [
    (self: super: {
      rng-tools = super.rng-tools.override { withPkcs11 = false; };
    })
  ];

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
    "192.168.1.148" =
      [ "thanos" "binarycache.thanos" "restic.thanos" "pihole.thanos" ];
    "192.168.1.20" = [ "nebula" "pihole.nebula" ];
    "192.168.1.77" = [ "riza" ];
    "192.168.1.121" = [ "orion" ];
  };

  #
  # Services
  #

  services.dnsmasq.enable = true;
  services.dnsmasq.extraConfig = ''
    domain-needed
    bogus-priv
    no-resolv

    server=1.1.1.1
    server=1.0.0.1

    cache-size=400
    local-ttl=300

    conf-file=/etc/assets/hosts-blocklists/domains.txt
    addn-hosts=/etc/assets/hosts-blocklists/hostnames.txt
  '';

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
    hashedPassword =
      "$6$22Tois4OjFC$y3kfcuR7BBHVj8LnZNIfLyNhQOdVZkkTseXCNbiA95WS2JSXv4Zynmy8Ie9nCxNokgSL8cuO1Le0m4VHuzXXI.";
    extraGroups = [ "wheel" "bluetooth" "vboxusers" ];
    subUidRanges = [{
      startUid = 100000;
      count = 65536;
    }];
    subGidRanges = [{
      startGid = 100000;
      count = 65536;
    }];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDFErWB61gZadEEFteZYWZm8QRwabpl4kDHXsm0/rsLqoyWJN5Y4zF4kowSGyf92LfJu9zNBs2viuT3vmsLfg6r4wkbVyujpEo3JLuV79r9K8LcM32wA52MvQYATEzxuamZPZCBT9fI/2M6bC9lz67RQ5IoENfjZVCstOegSmODmOvGUs6JjrB40slB+4YXCVFypYq3uTyejaBMtKdu1S4TWUP8WRy8cWYmCt1+a6ACV2yJcwnhSoU2+QKt14R4XZ4QBSk4hFgiw64Bb3WVQlfQjz3qA4j5Tc8P3PESKJcKW/+AsavN1I2FzdiX1CGo2OL7p9TcZjftoi5gpbmzRX05 j@riza"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQChHW69/lghzz2b6T8hj6cShYGGDNA7g+HhS+P7JAWT43NiCvM+0S3xYr0sY/MNBqTHIV/5e2prP4uaCq7uyNT/5s8LLm6at8dhrKN1RZWQpHD9FID5sgw4yv8HANyVpt1+zY6PoqmhAb+Bj/g/H3Ijb+AAWbvWKxUMoChC9nWd5G+ogPpPQmElg/aGxjAL0oSuwGHEO1wNvV4/ddKLEWiLNF8Xdc0s4QkQnJZhyZMa+oaerI4wF7GqsVzsYg4ppK6YbZt5rv41XCqKp889b2JZphRVlN7LvJxX11ttctxFvhSlqa+C/7QvoFiOo5wJxZrwH3P1rMRfIWwzYas/sWlx jophish@cardassia.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBML4JuxphjzZ/gKVLRAunKfTuFT6VVr6DfXduvsiHz j@orion"
    ];
  };

  #
  # Nix
  #
  nix.buildMachines = [
    {
      hostName = "riza";
      system = "x86_64-linux";
      maxJobs = 8;
      speedFactor = 2;
      supportedFeatures = [ "big-parallel" ]; # To get it to build linux
      mandatoryFeatures = [ ];
    }
    {
      hostName = "orion";
      sshUser = "nix";
      sshKey = "/root/.ssh/id_buildfarm";
      system = "x86_64-linux";
      maxJobs = 16;
      speedFactor = 4;
      supportedFeatures = [ "big-parallel" ]; # To get it to build linux
      mandatoryFeatures = [ ];
    }
  ];
  nix.distributedBuilds = true;

  system.autoUpgrade = {
    enable = true;
    randomizedDelaySec = "45min";
    flags = [ "-j1" "--option" "build-cores" "1" ];
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "20.09"; # Did you read the comment?
}
