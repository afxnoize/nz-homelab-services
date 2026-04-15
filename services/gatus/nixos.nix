{
  config,
  pkgs,
  lib,
  ...
}:
let
  serveJson = pkgs.writeText "gatus-ts-serve.json" (
    builtins.toJSON {
      TCP = {
        "443" = {
          HTTPS = true;
        };
      };
      Web = {
        "\${TS_CERT_DOMAIN}:443" = {
          Handlers = {
            "/" = {
              Proxy = "http://127.0.0.1:8080";
            };
          };
        };
      };
    }
  );

in
{
  # sops secrets
  sops.secrets."gatus/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    key = "ts_authkey";
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
  sops.secrets."gatus/ts_domain" = {
    sopsFile = ./secrets.yaml;
    key = "ts_domain";
    restartUnits = [ "podman-gatus.service" ];
  };

  # sops templates: generate files with secrets embedded at activation time
  sops.templates."gatus-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder."gatus/ts_authkey"}
  '';
  sops.templates."gatus-config.yaml".content = builtins.toJSON {
    storage = {
      type = "sqlite";
      path = "/data/gatus.db";
    };
    ui = {
      title = "nz-homelab";
      header = "nz-homelab Status";
    };
    alerting = {
      telegram = {
        token = config.sops.placeholder."gatus/telegram_bot_token";
        id = config.sops.placeholder."gatus/telegram_chat_id";
        default-alert = {
          failure-threshold = 3;
          success-threshold = 1;
          send-on-resolved = true;
        };
      };
    };
    endpoints = [
      {
        name = "Vaultwarden";
        group = "services";
        url = "https://vaultwarden.${config.sops.placeholder."gatus/ts_domain"}/alive";
        interval = "30s";
        conditions = [ "[STATUS] == 200" ];
        alerts = [ { type = "telegram"; } ];
      }
      {
        name = "AdGuard Home";
        group = "services";
        url = "https://adguard-home.${config.sops.placeholder."gatus/ts_domain"}/login.html";
        interval = "30s";
        conditions = [ "[STATUS] == 200" ];
        alerts = [ { type = "telegram"; } ];
      }
    ];
  };

  virtualisation.oci-containers.containers = {
    # Tailscale sidecar
    gatus-ts = {
      image = "docker.io/tailscale/tailscale:latest";
      autoStart = true;
      environment = {
        TS_HOSTNAME = "gatus";
        TS_STATE_DIR = "/var/lib/tailscale";
        TS_SERVE_CONFIG = "/config/serve.json";
        TS_USERSPACE = "true";
      };
      environmentFiles = [
        config.sops.templates."gatus-ts.env".path
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
      volumes = [
        "gatus-data:/data"
        "${config.sops.templates."gatus-config.yaml".path}:/config/config.yaml:ro"
      ];
      extraOptions = [
        "--network=container:gatus-ts"
      ];
    };
  };
}
