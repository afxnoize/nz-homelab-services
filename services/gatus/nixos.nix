{ config, pkgs, lib, ... }:
let
  serveJson = pkgs.writeText "gatus-ts-serve.json" (builtins.toJSON {
    TCP = { "443" = { HTTPS = true; }; };
    Web = {
      ":443" = {
        Handlers = {
          "/" = { Proxy = "http://127.0.0.1:8080"; };
        };
      };
    };
  });

  # NOTE: sops-nix writes secret values as plain text (not KEY=VALUE format).
  # environmentFiles here passes the raw secret value file directly to the container.
  # This works for TS_AUTHKEY (Tailscale reads it automatically via the env file),
  # but TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID require KEY=VALUE format.
  # If Gatus does not expand env vars from plain-text files, these may need
  # to be injected via an entrypoint wrapper or sops template instead.
  configYaml = pkgs.writeText "gatus-config.yaml" ''
    storage:
      type: sqlite
      path: /data/gatus.db

    ui:
      title: nz-homelab
      header: nz-homelab Status

    alerting:
      telegram:
        token: "''${TELEGRAM_BOT_TOKEN}"
        id: "''${TELEGRAM_CHAT_ID}"
        default-alert:
          failure-threshold: 3
          success-threshold: 1
          send-on-resolved: true

    endpoints:
      - name: Vaultwarden
        group: services
        url: "https://vaultwarden:443/alive"
        interval: 30s
        conditions:
          - "[STATUS] == 200"
        alerts:
          - type: telegram

      - name: AdGuard Home
        group: services
        url: "https://adguard-home:443/login.html"
        interval: 30s
        conditions:
          - "[STATUS] == 200"
        alerts:
          - type: telegram
  '';
in {
  # sops secrets
  sops.secrets."gatus/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    restartUnits = [ "podman-gatus-ts.service" ];
  };
  sops.secrets."gatus/telegram_bot_token" = {
    sopsFile = ./secrets.yaml;
    key = "TELEGRAM_BOT_TOKEN";
    restartUnits = [ "podman-gatus.service" ];
  };
  sops.secrets."gatus/telegram_chat_id" = {
    sopsFile = ./secrets.yaml;
    key = "TELEGRAM_CHAT_ID";
    restartUnits = [ "podman-gatus.service" ];
  };

  virtualisation.oci-containers.containers = {
    # Tailscale sidecar
    gatus-ts = {
      image = "docker.io/tailscale/tailscale:latest";
      autoStart = true;
      environment = {
        TS_HOSTNAME     = "gatus";
        TS_STATE_DIR    = "/var/lib/tailscale";
        TS_SERVE_CONFIG = "/config/serve.json";
        TS_USERSPACE    = "true";
      };
      # NOTE: sops-nix writes a plain-text value file, not KEY=VALUE.
      # Tailscale reads TS_AUTHKEY from this file via its own env-file mechanism.
      environmentFiles = [
        config.sops.secrets."gatus/ts_authkey".path
      ];
      volumes = [
        "gatus-ts-state:/var/lib/tailscale"
        "${serveJson}:/config/serve.json:ro"
      ];
      extraOptions = [
        "--health-cmd=tailscale status --json | grep -q '\"Online\": true' || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
        "--health-start-period=60s"
      ];
    };

    # Gatus
    gatus = {
      image = "ghcr.io/twin/gatus:stable";
      autoStart = true;
      dependsOn = [ "gatus-ts" ];
      # NOTE: sops-nix writes plain-text value files (not KEY=VALUE).
      # Gatus expands ${VAR} in config.yaml from environment variables,
      # so these files need to export KEY=VALUE pairs.
      # This may require sops templates or an entrypoint wrapper at deployment time.
      environmentFiles = [
        config.sops.secrets."gatus/telegram_bot_token".path
        config.sops.secrets."gatus/telegram_chat_id".path
      ];
      volumes = [
        "gatus-data:/data"
        "${configYaml}:/config/config.yaml:ro"
      ];
      extraOptions = [
        "--network=container:gatus-ts"
      ];
    };
  };
}
