{ config, pkgs, ... }:

let
  minio-dir = "/data/minio";
  minio-data = "${minio-dir}/data";
  minio-config = "${minio-dir}/config";
  minio-port = "9002";
  region = "ap-southeast-1";

  # This bucket will be present in the instance
  bucket = "nix-cache";
  user-name = "nix";

  # Settings from the Nix manual
  # https://nixos.org/manual/nix/stable/#ssec-s3-substituter-authenticated-writes
  upload-policy = pkgs.writeText "nix-cache-write.json" ''
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "UploadToCache",
          "Effect": "Allow",
          "Action": [
            "s3:AbortMultipartUpload",
            "s3:GetBucketLocation",
            "s3:GetObject",
            "s3:ListBucket",
            "s3:ListBucketMultipartUploads",
            "s3:ListMultipartUploadParts",
            "s3:PutObject"
          ],
          "Resource": [
            "arn:aws:s3:::${bucket}",
            "arn:aws:s3:::${bucket}/*"
          ]
        }
      ]
    }
  '';

  # nginx config from the minio documentation
  host-config = ''
    # To allow special characters in headers
    ignore_invalid_headers off;
    # Allow any size file to be uploaded.
    client_max_body_size 0;
    # To disable buffering
    proxy_buffering off;
  '';

  location-config = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_connect_timeout 300;
    # Default is HTTP/1, keepalive is only enabled in HTTP/1.1
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    chunked_transfer_encoding off;
  '';
in
{
  # Expose this minio cluster with nginx
  services.nginx = {
    virtualHosts = {
      "binarycache.thanos" = {
        extraConfig = host-config;
        locations."/" = {
          proxyPass = "http://localhost:${minio-port}";
          extraConfig = ''
            allow 192.168.1.0/24;
            allow 127.0.0.1;
            deny all;
          '' + location-config;
        };
      };
      "binarycache.home.monoid.al" = {
        forceSSL = true;
        enableACME = true;
        extraConfig = host-config;
        locations = {
          "/" = {
            proxyPass = "http://localhost:${minio-port}";
            extraConfig = location-config;
          };
        };
      };
    };
  };

  # Create a user and group for minio
  users.users.minio = {
    group = "minio";
    uid = config.ids.uids.minio;
  };
  users.groups.minio.gid = config.ids.uids.minio;

  # Make sure these directories exist and have correct ownership
  systemd.tmpfiles.rules = [
    "d '${minio-config}' - minio minio - -"
    "d '${minio-data}' - minio minio - -"
  ];

  # Largely from https://github.com/NixOS/nixpkgs/issues/89559
  systemd.services.minio = {
    enable = true;
    # Most of this is for the start health check
    path = [ pkgs.minio pkgs.coreutils pkgs.bash pkgs.curl ];
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "minio";
      Group = "minio";
      LimitNOFILE = 65536;
      # Wait until the service is up before continuing, this is important to
      # make sure the minio-config job doesn't start too quickly.
      ExecStartPost= ''${pkgs.coreutils}/bin/timeout 30 sh -c 'while ! curl --silent --fail http://localhost:${minio-port}/minio/health/cluster; do sleep 1; done' '';
    };
    script = ''
      set -e
      export MINIO_REGION=${region}
      export MINIO_BROWSER=off
      export MINIO_ACCESS_KEY=$(<"${minio-dir}/keys/minio-access-key")
      export MINIO_SECRET_KEY=$(<"${minio-dir}/keys/minio-secret-key")
      minio server --address localhost:${minio-port} --config-dir "${minio-config}" "${minio-data}"
    '';
  };

  # Poor person's declarative minio configuration. It's idempotent at least I
  # think.
  systemd.services.minio-config = {
    enable = true;
    path = [ pkgs.minio pkgs.minio-client];
    requiredBy = [ "multi-user.target" ];
    after = [ "minio.service" ];
    serviceConfig = {
      Type = "simple";
      User = "minio";
      Group = "minio";
      RuntimeDirectory = "minio-config";
    };
    script = ''
      set -e
      export MINIO_ACCESS_KEY=$(<"${minio-dir}/keys/minio-access-key")
      export MINIO_SECRET_KEY=$(<"${minio-dir}/keys/minio-secret-key")
      CLIENT_ACCESS_KEY=${user-name}
      CLIENT_SECRET_KEY=$(<"${minio-dir}/keys/${user-name}-secret-key")
      CONFIG_DIR=$RUNTIME_DIRECTORY
      mc --config-dir "$CONFIG_DIR" config host add minio http://localhost:${minio-port} "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"
      mc --config-dir "$CONFIG_DIR" admin user add minio "$CLIENT_ACCESS_KEY" "$CLIENT_SECRET_KEY"
      mc --config-dir "$CONFIG_DIR" admin policy add minio POLICY "${upload-policy}"
      mc --config-dir "$CONFIG_DIR" admin policy set minio POLICY user="$CLIENT_ACCESS_KEY"
      mc --config-dir "$CONFIG_DIR" mb --ignore-existing minio/${bucket}
    '';
  };
}
