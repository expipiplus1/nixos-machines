{ config, pkgs, lib, ... }:

with lib;

let
  dataDir = "/var/lib/mautrix-signal";
  registrationFile = "${dataDir}/signal-registration.yaml";
  cfg = config.services.mautrix-signal;
  settingsFormat = pkgs.formats.json {};
  settingsFileUnsubstituted = settingsFormat.generate "mautrix-signal-config-unsubstituted.json" cfg.settings;
  settingsFile = "${dataDir}/config.json";

in {
  options = {
    services.mautrix-signal = {
      enable = mkEnableOption "Mautrix-Signal, a Matrix-Signal hybrid puppeting bridge";

      settings = mkOption rec {
        apply = recursiveUpdate default;
        inherit (settingsFormat) type;
        default = {
          appservice = rec {
            database = "postgresql:///mautrix-signal?host=/run/postgresql";
            database_opts = {};
            hostname = "0.0.0.0";
            port = 29328;
            address = "http://localhost:${toString port}";
          };

          bridge = {
            permissions = {};
            double_puppet_server_map = {};
            login_shared_secret_map = {};
          };

          logging = {
            version = 1;

            formatters.precise.format = "[%(levelname)s@%(name)s] %(message)s";

            handlers.console = {
              class = "logging.StreamHandler";
              formatter = "precise";
            };

            loggers = {
              mau.level = "INFO";
              telethon.level = "INFO";

              # prevent tokens from leaking in the logs:
              # https://github.com/tulir/mautrix-signal/issues/351
              aiohttp.level = "WARNING";
            };

            # log to console/systemd instead of file
            root = {
              level = "INFO";
              handlers = [ "console" ];
            };
          };
        };
        example = literalExample ''
          {
            homeserver = {
              address = "http://localhost:8008";
              domain = "public-domain.tld";
            };

            appservice.public = {
              prefix = "/public";
              external = "https://public-appservice-address/public";
            };

            bridge.permissions = {
              "example.com" = "full";
              "@admin:example.com" = "admin";
            };
          }
        '';
        description = ''
          <filename>config.yaml</filename> configuration as a Nix attribute set.
          Configuration options should match those described in
          <link xlink:href="https://github.com/tulir/mautrix-signal/blob/master/mautrix_signal/example-config.yaml">
          example-config.yaml</link>.
          </para>

          <para>
          Secret tokens should be specified using <option>environmentFile</option>
          instead of this world-readable attribute set.
        '';
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          File containing environment variables to be passed to the mautrix-signal service,
          in which secret tokens can be specified securely by defining values for
          <literal>MAUTRIX_SIGNAL_APPSERVICE_AS_TOKEN</literal>,
          <literal>MAUTRIX_SIGNAL_APPSERVICE_HS_TOKEN</literal>,
        '';
      };

      serviceDependencies = mkOption {
        type = with types; listOf str;
        default = optional config.services.matrix-synapse.enable "matrix-synapse.service";
        description = ''
          List of Systemd services to require and wait for when starting the application service.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services.mautrix-signal = {
      description = "Mautrix-Signal, a Matrix-Signal hybrid puppeting/relaybot bridge.";

      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" "signald.target" ];
      after = [ "network-online.target" "signald.target" ];

      preStart = ''
        # Not all secrets can be passed as environment variable (yet)
        [ -f ${settingsFile} ] && rm -f ${settingsFile}
        old_umask=$(umask)
        umask 0277
        ${pkgs.envsubst}/bin/envsubst \
          -o ${settingsFile} \
          -i ${settingsFileUnsubstituted}
        umask $old_umask

        # generate the appservice's registration file if absent
        if [ ! -f '${registrationFile}' ]; then
          ${pkgs.mautrix-signal}/bin/mautrix-signal \
            --generate-registration \
            --base-config='${pkgs.mautrix-signal}/${pkgs.mautrix-signal.pythonModule.sitePackages}/mautrix_signal/example-config.yaml' \
            --config='${settingsFile}' \
            --registration='${registrationFile}'
        fi
      '';

      serviceConfig = {
        Type = "simple";
        Restart = "always";

        ProtectSystem = "full";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;

        DynamicUser = true;
        SupplementaryGroups = [ "signald" ];
        BindPaths = "/var/lib/signald";
        StateDirectory = baseNameOf dataDir;
        UMask = 0023;
        EnvironmentFile = cfg.environmentFile;

        ExecStart = ''
          ${pkgs.mautrix-signal}/bin/mautrix-signal \
            --config='${settingsFile}'
        '';
      };
      unitConfig = {
        JoinsNamespaceOf = "signald.service";
      };

      restartTriggers = [ settingsFileUnsubstituted ];
    };
  };

  meta.maintainers = with maintainers; [ expipiplus1 ];
}
