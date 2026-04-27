{
  config,
  pkgs,
  lib,
  ...
}:
let
  serveJson = pkgs.writeText "adguard-home-ts-serve.json" (
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
              Proxy = "http://127.0.0.1:3000";
            };
          };
        };
      };
    }
  );
  adguardConfig = ./AdGuardHome.yaml;
in
{
  # sops secrets
  sops.secrets."adguard-home/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    key = "ts_authkey";
    restartUnits = [ "adguard-home-ts.service" ];
  };

  # sops template: generate KEY=VALUE env file for Podman --env-file
  sops.templates."adguard-home-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder."adguard-home/ts_authkey"}
  '';

  virtualisation.quadlet.containers = {
    # Tailscale sidecar
    adguard-home-ts = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/tailscale/tailscale:latest";
        environments = {
          TS_HOSTNAME = "adguard-home";
          TS_STATE_DIR = "/var/lib/tailscale";
          TS_SERVE_CONFIG = "/config/serve.json";
          TS_USERSPACE = "true";
          TS_EXTRA_ARGS = "--accept-dns=false";
        };
        environmentFiles = [
          config.sops.templates."adguard-home-ts.env".path
        ];
        volumes = [
          "adguard-home-ts-state:/var/lib/tailscale"
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

    # AdGuard Home
    adguard-home = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/adguard/adguardhome:latest";
        networks = [ "container:adguard-home-ts" ];
        volumes = [
          "adguard-home-data:/opt/adguardhome/work/data"
          "adguard-home-conf:/opt/adguardhome/conf"
        ];
        healthCmd = "wget --quiet --tries=1 --spider http://127.0.0.1:3000 || exit 1";
        healthInterval = "30s";
        healthTimeout = "10s";
        healthRetries = 3;
        healthStartPeriod = "60s";
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "adguard-home-ts.service" ];
        After = [ "adguard-home-ts.service" ];
      };
      serviceConfig = {
        Restart = "always";
        # Seed AdGuardHome.yaml into the conf volume before container starts
        # (file bind mount causes "device or resource busy" on atomic rename)
        ExecStartPre = lib.mkAfter [
          "-${pkgs.podman}/bin/podman volume create adguard-home-conf"
          "${pkgs.coreutils}/bin/install -m 644 ${adguardConfig} /var/lib/containers/storage/volumes/adguard-home-conf/_data/AdGuardHome.yaml"
        ];
      };
    };
  };
}
