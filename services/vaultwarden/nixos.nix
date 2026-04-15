{
  config,
  pkgs,
  lib,
  ...
}:
let
  serveJson = pkgs.writeText "vaultwarden-ts-serve.json" (
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
              Proxy = "http://127.0.0.1:80";
            };
          };
        };
      };
    }
  );
in
{
  # sops secrets
  sops.secrets."vaultwarden/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    key = "ts_authkey";
    restartUnits = [ "vaultwarden-ts.service" ];
  };

  # sops template: generate KEY=VALUE env file for Podman --env-file
  sops.templates."vaultwarden-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder."vaultwarden/ts_authkey"}
  '';

  virtualisation.quadlet.containers = {
    # Tailscale sidecar
    vaultwarden-ts = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/tailscale/tailscale:latest";
        environments = {
          TS_HOSTNAME = "vaultwarden";
          TS_STATE_DIR = "/var/lib/tailscale";
          TS_SERVE_CONFIG = "/config/serve.json";
          TS_USERSPACE = "true";
        };
        environmentFiles = [
          config.sops.templates."vaultwarden-ts.env".path
        ];
        volumes = [
          "vaultwarden-ts-state:/var/lib/tailscale"
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

    # Vaultwarden
    vaultwarden = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/vaultwarden/server:latest";
        environments = {
          SIGNUPS_ALLOWED = "true";
        };
        networks = [ "container:vaultwarden-ts" ];
        volumes = [
          "vaultwarden-data:/data"
        ];
        healthCmd = "curl --fail --silent http://127.0.0.1:80/alive || exit 1";
        healthInterval = "30s";
        healthTimeout = "10s";
        healthRetries = 3;
        healthStartPeriod = "40s";
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "vaultwarden-ts.service" ];
        After = [ "vaultwarden-ts.service" ];
      };
      serviceConfig.Restart = "always";
    };
  };
}
