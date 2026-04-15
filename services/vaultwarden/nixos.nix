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
    restartUnits = [ "podman-vaultwarden-ts.service" ];
  };

  # sops template: generate KEY=VALUE env file for Podman --env-file
  sops.templates."vaultwarden-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder."vaultwarden/ts_authkey"}
  '';

  virtualisation.oci-containers.containers = {
    # Tailscale sidecar
    vaultwarden-ts = {
      image = "docker.io/tailscale/tailscale:latest";
      autoStart = true;
      environment = {
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
      extraOptions = [
        "--health-cmd=tailscale status --json | grep -q '\"Online\": true' || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
        "--health-start-period=60s"
      ];
    };

    # Vaultwarden
    vaultwarden = {
      image = "docker.io/vaultwarden/server:latest";
      autoStart = true;
      dependsOn = [ "vaultwarden-ts" ];
      environment = {
        SIGNUPS_ALLOWED = "true";
      };
      volumes = [
        "vaultwarden-data:/data"
      ];
      extraOptions = [
        "--network=container:vaultwarden-ts"
        "--health-cmd=curl --fail --silent http://127.0.0.1:80/alive || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
        "--health-start-period=40s"
      ];
    };
  };
}
