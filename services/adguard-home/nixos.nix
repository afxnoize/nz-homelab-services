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

  fluentBitConf = pkgs.writeText "adguard-home-fluent-bit.conf" ''
    [SERVICE]
        Flush        5
        Log_Level    warn
        Daemon       off
        Parsers_File /fluent-bit/etc/parsers.conf

    [INPUT]
        Name         tail
        Path         /data/querylog.json
        Tag          adguard.querylog
        Parser       json
        DB           /state/tail-pos.db
        Refresh_Interval 10
        Read_from_Head false

    [OUTPUT]
        Name         stdout
        Match        *
        Format       json_lines
  '';

  parsersConf = pkgs.writeText "adguard-home-parsers.conf" ''
    [PARSER]
        Name         json
        Format       json
        Time_Key     T
        Time_Format  %Y-%m-%dT%H:%M:%S.%L%z
        Time_Keep    On
  '';
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

    # Fluent-bit querylog sidecar
    adguard-home-querylog = {
      autoStart = true;
      containerConfig = {
        image = "ghcr.io/fluent/fluent-bit:latest";
        volumes = [
          "adguard-home-data:/data:ro"
          "adguard-home-querylog-state:/state"
          "${fluentBitConf}:/fluent-bit/etc/fluent-bit.conf:ro"
          "${parsersConf}:/fluent-bit/etc/parsers.conf:ro"
        ];
        exec = [
          "/fluent-bit/bin/fluent-bit"
          "-c"
          "/fluent-bit/etc/fluent-bit.conf"
        ];
        logDriver = "journald";
      };
      unitConfig = {
        Requires = [ "adguard-home.service" ];
        After = [ "adguard-home.service" ];
      };
      serviceConfig.Restart = "always";
    };
  };
}
