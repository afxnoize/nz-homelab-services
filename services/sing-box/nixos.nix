{
  config,
  pkgs,
  lib,
  ...
}:
let
  # AdGuard Home の Tailscale IP (Tailscale node の安定 IP)
  # 参考: MagicDNS 名は adguard-home.<tailnet>.ts.net だが、
  # 起動順依存を避けるため IP リテラルを採用 (ADR-012)
  adguardDnsHost = "100.111.180.68";

  singBoxConfig = pkgs.writeText "sing-box-config.json" (
    builtins.toJSON {
      log = {
        level = "info";
        timestamp = true;
      };
      dns = {
        servers = [
          {
            tag = "adguard";
            address = adguardDnsHost;
          }
        ];
        final = "adguard";
      };
      inbounds = [
        {
          type = "socks";
          tag = "socks-in";
          listen = "0.0.0.0";
          listen_port = 1080;
        }
        {
          type = "http";
          tag = "http-in";
          listen = "0.0.0.0";
          listen_port = 8080;
        }
      ];
      outbounds = [
        {
          type = "direct";
          tag = "direct";
        }
      ];
      route = {
        final = "direct";
      };
    }
  );
in
{
  # sops secrets
  sops.secrets."sing-box/ts_authkey" = {
    sopsFile = ./secrets.yaml;
    key = "ts_authkey";
    restartUnits = [ "sing-box-ts.service" ];
  };

  # sops template: Tailscale env file
  sops.templates."sing-box-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder."sing-box/ts_authkey"}
  '';

  virtualisation.quadlet.containers = {
    # Tailscale sidecar
    sing-box-ts = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/tailscale/tailscale:latest";
        environments = {
          TS_HOSTNAME = "sing-box";
          TS_STATE_DIR = "/var/lib/tailscale";
          TS_USERSPACE = "true";
        };
        environmentFiles = [
          config.sops.templates."sing-box-ts.env".path
        ];
        volumes = [
          "sing-box-ts-state:/var/lib/tailscale"
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

    # sing-box
    sing-box = {
      autoStart = true;
      containerConfig = {
        image = "ghcr.io/sagernet/sing-box:latest";
        networks = [ "container:sing-box-ts" ];
        volumes = [
          "${singBoxConfig}:/etc/sing-box/config.json:ro"
        ];
        exec = [
          "-c"
          "/etc/sing-box/config.json"
          "run"
        ];
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "sing-box-ts.service" ];
        After = [ "sing-box-ts.service" ];
      };
      serviceConfig.Restart = "always";
    };
  };

  # Named volumes
  virtualisation.quadlet.volumes = {
    sing-box-ts-state = { };
  };
}
