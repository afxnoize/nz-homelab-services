{
  config,
  pkgs,
  lib,
  vars,
}:
{
  virtualisation.quadlet.containers.victoriametrics = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/victoriametrics/victoria-metrics:latest";
      networks = [ "host" ];
      exec = [
        "-storageDataPath=/storage"
        "-retentionPeriod=${vars.retention.metrics}"
        "-httpListenAddr=:${toString vars.ports.vm}"
      ];
      volumes = [
        "victoriametrics-data:/storage"
      ];
      healthCmd = "wget --spider -q http://127.0.0.1:${toString vars.ports.vm}/health || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthRetries = 3;
      healthStartPeriod = "30s";
      logDriver = "journald";
    };
    serviceConfig.Restart = "always";
  };
}
