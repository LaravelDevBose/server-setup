# Template. setup.sh renders it to prometheus-agent.yml (Prometheus cannot expand env vars).
global:
  scrape_interval: 15s
  external_labels:
    host: @HOST_NAME@

remote_write:
  - url: @INGEST_URL@/api/v1/write
    basic_auth:
      username: @INGEST_USER@
      password_file: /etc/prometheus/ingest_password

scrape_configs:
  - job_name: node-exporter
    static_configs: [{targets: ['node-exporter:9100']}]
  - job_name: cadvisor
    static_configs: [{targets: ['cadvisor:8080']}]
