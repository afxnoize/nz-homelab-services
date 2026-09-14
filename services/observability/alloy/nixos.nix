{
  config,
  pkgs,
  lib,
  vars,
}:
let
  alloyConfig = ./config.alloy;
in
{
  virtualisation.quadlet.containers.alloy = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/grafana/alloy:latest";
      networks = [ "host" ];
      exec = [
        "run"
        "--server.http.listen-addr=127.0.0.1:${toString vars.ports.alloy}"
        "/etc/alloy/config.alloy"
      ];
      volumes = [
        "${alloyConfig}:/etc/alloy/config.alloy:ro"
        "/var/log/journal:/var/log/journal:ro"
        "/etc/machine-id:/etc/machine-id:ro"
        "adguard-home-data:/var/log/adguard:ro"
        "alloy-data:/var/lib/alloy"
        # Host mounts for prometheus.exporter.unix (see K-019):
        # without these the exporter sees only the container's overlay fs
        # and host filesystem metrics (mountpoint="/") are silently missing
        "/:/rootfs:ro,rslave"
        "/proc:/host/proc:ro"
        "/sys:/host/sys:ro"
      ];
      healthCmd = "wget --spider -q http://127.0.0.1:${toString vars.ports.alloy}/-/healthy || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthRetries = 3;
      healthStartPeriod = "60s";
      logDriver = "journald";
    };
    unitConfig = {
      Requires = [
        "victorialogs.service"
        "victoriametrics.service"
      ];
      After = [
        "victorialogs.service"
        "victoriametrics.service"
      ];
    };
    serviceConfig.Restart = "always";
  };
}
