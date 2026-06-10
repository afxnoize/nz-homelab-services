{
  config,
  pkgs,
  lib,
  vars,
}:
let
  serveJson = pkgs.writeText "grafana-ts-serve.json" (
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
              Proxy = "http://127.0.0.1:${toString vars.ports.grafana}";
            };
          };
        };
      };
    }
  );
in
{
  virtualisation.quadlet.containers = {
    # Tailscale sidecar
    grafana-ts = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/tailscale/tailscale:latest";
        environments = {
          TS_HOSTNAME = "grafana";
          TS_STATE_DIR = "/var/lib/tailscale";
          TS_SERVE_CONFIG = "/config/serve.json";
          TS_USERSPACE = "true";
        };
        environmentFiles = [
          config.sops.templates."grafana-ts.env".path
        ];
        volumes = [
          "grafana-ts-state:/var/lib/tailscale"
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

    # Grafana
    grafana = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/grafana/grafana:latest";
        environments = {
          GF_INSTALL_PLUGINS = "victoriametrics-logs-datasource";
        };
        environmentFiles = [
          config.sops.templates."grafana.env".path
        ];
        networks = [ "container:grafana-ts" ];
        volumes = [
          "grafana-data:/var/lib/grafana"
          "${./provisioning}:/etc/grafana/provisioning:ro"
        ];
        healthCmd = "wget --spider -q http://127.0.0.1:${toString vars.ports.grafana}/api/health || exit 1";
        healthInterval = "30s";
        healthTimeout = "10s";
        healthRetries = 3;
        healthStartPeriod = "60s";
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "grafana-ts.service" ];
        After = [ "grafana-ts.service" ];
      };
      serviceConfig.Restart = "always";
    };
  };
}
