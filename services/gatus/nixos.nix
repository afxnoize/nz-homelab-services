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
    restartUnits = [ "gatus-ts.service" ];
  };
  sops.secrets."gatus/telegram_bot_token" = {
    sopsFile = ./secrets.yaml;
    key = "TELEGRAM_BOT_TOKEN";
    restartUnits = [ "gatus.service" ];
  };
  sops.secrets."gatus/telegram_chat_id" = {
    sopsFile = ./secrets.yaml;
    key = "TELEGRAM_CHAT_ID";
    restartUnits = [ "gatus.service" ];
  };
  sops.secrets."gatus/ts_domain" = {
    sopsFile = ./secrets.yaml;
    key = "ts_domain";
    restartUnits = [ "gatus.service" ];
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

  virtualisation.quadlet.containers = {
    # Tailscale sidecar
    gatus-ts = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/tailscale/tailscale:latest";
        environments = {
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
        healthCmd = "tailscale status --json | grep -q '\"Online\": true' || exit 1";
        healthInterval = "30s";
        healthTimeout = "10s";
        healthRetries = 3;
        healthStartPeriod = "60s";
        logDriver = "journald";
      };
      serviceConfig.Restart = "always";
    };

    # Gatus
    gatus = {
      autoStart = true;
      containerConfig = {
        image = "ghcr.io/twin/gatus:stable";
        networks = [ "container:gatus-ts" ];
        volumes = [
          "gatus-data:/data"
          "${config.sops.templates."gatus-config.yaml".path}:/config/config.yaml:ro"
        ];
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "gatus-ts.service" ];
        After = [ "gatus-ts.service" ];
      };
      serviceConfig.Restart = "always";
    };
  };
}
