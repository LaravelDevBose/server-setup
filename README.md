# Monitoring Stack

Prometheus · cAdvisor · Node Exporter · Grafana — hosted on Docker, exposed via Traefik.

---

## Services

### Prometheus
**What:** Time-series metrics database and scrape engine.  
**Why:** Central store for all metrics. Pulls (scrapes) data from exporters on a schedule and stores it for querying.  
**Port:** internal `9090` (not exposed to host).

### Node Exporter
**What:** Exposes host-level hardware and OS metrics.  
**Why:** Without this, you're blind to CPU load, memory pressure, disk I/O, network throughput — the physical health of the VPS itself.  
**Port:** internal `9100`.  
**Metrics include:** CPU usage, memory/swap, disk space, disk I/O, network bytes/packets, load average, filesystem stats.

### cAdvisor
**What:** Exposes per-container resource metrics from the Docker daemon.  
**Why:** Node Exporter sees the host; cAdvisor sees each container individually — CPU throttling, memory limits, network per container. Essential for identifying which container is misbehaving.  
**Port:** internal `8080`.  
**Metrics include:** container CPU/memory/network/disk, container restart count, OOM events.

### Grafana
**What:** Visualization and dashboarding layer.  
**Why:** Raw Prometheus metrics are unreadable. Grafana queries Prometheus and renders charts, alerts, and dashboards.  
**Port:** `3000` → exposed publicly via Traefik at `https://monitor.yourdomain.com`.

---

## Architecture

```
Internet
   │  HTTPS
   ▼
Traefik (proxy network)
   │  :3000
   ▼
Grafana ──────────────────────────────────┐
   │  PromQL queries                       │ backend network (bcs-net)
   ▼                                       │
Prometheus ◄── scrape :9100 ── Node Exporter
           ◄── scrape :8080 ── cAdvisor
```

- **Traefik** terminates TLS and forwards traffic to Grafana only. Nothing else is internet-facing.
- **Grafana** sits on both `proxy` (for Traefik) and `backend` (to reach Prometheus).
- **Prometheus, Node Exporter, cAdvisor** sit only on `backend` — no public exposure.
- Prometheus pulls metrics every **15 seconds**. Data retained for **15 days**.

---

## Deployment Guide

### Prerequisites

- Docker + Docker Compose v2 installed on the VPS.
- Traefik running and attached to the `proxy` network.
- `bcs-net` Docker network exists (`docker network ls` to verify).
- DNS A record for `monitor.yourdomain.com` pointing to the VPS IP.

### 1. Configure environment

Edit `monitoring/.env`:

```env
GRAFANA_DOMAIN=monitor.yourdomain.com   # your actual domain
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=ChangeThisNow!   # use a strong password
```

### 2. Verify external networks exist

```bash
docker network ls | grep -E 'proxy|bcs-net'
```

If missing, create them:

```bash
docker network create proxy
docker network create bcs-net
```

### 3. Deploy

```bash
cd monitoring
docker compose up -d
```

### 4. Verify all containers are running

```bash
docker compose ps
```

All 4 services should show `running`. If any exit immediately:

```bash
docker compose logs <service-name>
```

### 5. Access Grafana

Open `https://monitor.yourdomain.com` in browser. TLS certificate issued automatically by Traefik via ACME.

---

## User Manual

### First Login

1. Navigate to `https://monitor.yourdomain.com`.
2. Login with credentials from `.env` (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`).
3. Change password when prompted (or skip; you can change it later under Profile).

### Add Prometheus as Data Source

This is required once after first deploy:

1. Go to **Connections → Data sources → Add data source**.
2. Select **Prometheus**.
3. Set URL to `http://prometheus:9090`.
4. Click **Save & test** — should show "Successfully queried".

### Import Dashboards

Use community dashboards from [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards).

Recommended IDs:

| Dashboard | ID |
|---|---|
| Node Exporter Full (host metrics) | `1860` |
| cAdvisor (container metrics) | `14282` |

**To import:** Dashboards → New → Import → enter ID → Load → select Prometheus data source → Import.

### Explore Metrics Manually

Go to **Explore**, select Prometheus data source, and run PromQL queries:

```promql
# CPU usage % per core
100 - (avg by(cpu) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory used (bytes)
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# Container CPU usage
rate(container_cpu_usage_seconds_total{name!=""}[5m])

# Container memory usage
container_memory_usage_bytes{name!=""}
```

### Set Up Alerts

1. Go to **Alerting → Alert rules → New alert rule**.
2. Define a PromQL condition (e.g., CPU > 80% for 5 minutes).
3. Configure notification channel under **Alerting → Contact points**.

### Update Stack

```bash
cd monitoring
docker compose pull          # pull new images
docker compose up -d         # recreate changed containers
```

### Stop Stack

```bash
docker compose down          # stops and removes containers, keeps volumes
docker compose down -v       # also removes volumes (DELETES all data)
```

---

## File Reference

```
monitoring/
├── .env                 # secrets and domain config (do not commit)
├── prometheus.yml       # scrape targets config
├── docker-compose.yml   # service definitions
└── README.md
```

## Data Persistence

| Volume | Contains |
|---|---|
| `prometheus_data` | All scraped metrics (15-day window) |
| `grafana_data` | Dashboards, users, data source config |

Volumes survive `docker compose down`. Use `docker volume ls` to inspect.
