{
  config,
  pkgs,
  lib,
  vars,
}:
{
  virtualisation.quadlet.containers.victorialogs = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/victoriametrics/victoria-logs:latest";
      networks = [ "host" ];
      exec = [
        "-storageDataPath=/storage"
        "-retentionPeriod=${vars.retention.logs}"
        "-retention.maxDiskSpaceUsageBytes=${vars.diskBudget.logs}"
        "-httpListenAddr=:${toString vars.ports.vl}"
      ];
      volumes = [
        "victorialogs-data:/storage"
      ];
      healthCmd = "wget --spider -q http://127.0.0.1:${toString vars.ports.vl}/health || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthRetries = 3;
      healthStartPeriod = "30s";
      logDriver = "journald";
    };
    serviceConfig.Restart = "always";
  };
}
