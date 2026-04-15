{
  config,
  pkgs,
  lib,
  ...
}:
{
  # sops secrets
  # NOTE: These secrets are used by the manual `kopia repository connect` step.
  # After migration, run: just backup connect  (or the equivalent manual commands)
  # to connect the repository using these values.
  sops.secrets."backup/b2_endpoint" = {
    sopsFile = ./secrets.yaml;
    key = "b2_endpoint";
  };
  sops.secrets."backup/b2_bucket" = {
    sopsFile = ./secrets.yaml;
    key = "b2_bucket";
  };
  sops.secrets."backup/b2_key_id" = {
    sopsFile = ./secrets.yaml;
    key = "b2_key_id";
  };
  sops.secrets."backup/b2_secret_key" = {
    sopsFile = ./secrets.yaml;
    key = "b2_secret_key";
  };
  sops.secrets."backup/kopia_password" = {
    sopsFile = ./secrets.yaml;
    key = "kopia_password";
  };

  environment.systemPackages = [ pkgs.kopia ];

  # NOTE: This is a stub. The kopia repository must be connected manually
  # before this service will succeed. Run:
  #   kopia --config-file=/var/lib/kopia/vault-b2.config repository connect s3 \
  #     --endpoint=<b2_endpoint> --bucket=<b2_bucket> \
  #     --access-key=<b2_key_id> --secret-access-key=<b2_secret_key> \
  #     --password=<kopia_password>
  # Backup sources are also configured manually after connecting the repository.
  systemd.services.kopia-backup = {
    description = "Kopia snapshot backup";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.kopia}/bin/kopia --config-file=/var/lib/kopia/vault-b2.config snapshot create --all";
    };
  };

  systemd.timers.kopia-backup = {
    description = "Daily Kopia backup";
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
  };
}
