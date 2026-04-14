# mqtt_broker_fly

EMQX 5.8.9 MQTT broker for OpenSeam, deployed on Fly.io.

Migrated from AWS Fargate (`mqtt_broker` repo). Identical broker behaviour, same credentials, same public endpoint — the migration is transparent to all MQTT clients including deployed AtomS3 seambits.

**Public endpoint**: `mqtt.seambit.openseam.io:1883`  
**Platform**: Fly.io, region `iad` (Ashburn, VA — closest to AWS us-east-1)  
**Machine**: `performance-1x` — 1 dedicated vCPU, 2 GB RAM

---

## What this is

MQTT is the real-time nervous system of the OpenSeam platform. Every sewing machine measurement from every deployed seambit device flows through this broker. See `webapp-portal/_IGNORE/_DOC/_1_SYSTEM/MQTT/MQTT-architecture.md` for the full architecture.

This repo contains the Docker image and Fly.io configuration. No application logic — EMQX is a third-party broker.

---

## Architecture

```
AtomS3 seambit devices  →  mqtt.seambit.openseam.io:1883  →  Fly.io (dedicated IPv4)  →  EMQX (this image)
backend pods            →                                  →                            →  EMQX (this image)
```

---

## Repository contents

| File | Purpose |
|---|---|
| `Dockerfile` | Extends `emqx/emqx:5.8.9`, installs `jq` for JSON parsing in bootstrap |
| `bootstrap.sh` | Startup wrapper — starts EMQX, waits for health, provisions MQTT users via API |
| `fly.toml` | Fly.io app configuration — TCP port 1883, performance machine, always-on |
| `deploy.sh` | One-command deployment script |

---

## How the bootstrap works

`bootstrap.sh` replaces the container entrypoint:

1. Sets `nofile` ulimit to 1,048,576 (supports 1M+ concurrent MQTT connections)
2. Starts EMQX in the background via the original `docker-entrypoint.sh`
3. Polls `GET /api/v5/status` until EMQX reports `running` (timeout: 120s)
4. Authenticates with the dashboard API to get a JWT token
5. Creates `seambit-client` and `seambit-web` users via the API (accepts 201 or 409)
6. `wait`s on the EMQX process — container exits when EMQX exits

Fully stateless. Users are re-provisioned on every start from Fly.io secrets. No volumes or external state required.

---

## MQTT users

| User | Secret name | Used by | Notes |
|---|---|---|---|
| `seambit-client` | `MQTT_SEAMBIT_CLIENT_PASSWORD` | AtomS3 firmware, `inference`, `seambit-status-server`, `seambit-s3-uploader` | Password hardcoded in firmware — do NOT change without coordinated firmware OTA |
| `seambit-web` | `MQTT_SEAMBIT_WEB_PASSWORD` | `worker_suspected_stoppage` and future business-logic workers | Rotatable |

---

## Fly.io secrets

Three secrets must be set before the first deployment:

```bash
flyctl secrets set \
  EMQX_DASHBOARD__DEFAULT_PASSWORD="..." \
  MQTT_SEAMBIT_CLIENT_PASSWORD="..." \
  MQTT_SEAMBIT_WEB_PASSWORD="..." \
  --app openseam-emqx
```

Values are the same as the AWS Secrets Manager secrets used by the Fargate version:
- `EMQX_DASHBOARD__DEFAULT_PASSWORD` ← `prod/emqx/dashboard_password`
- `MQTT_SEAMBIT_CLIENT_PASSWORD` ← `dev_seambit_MQTT_client_password`
- `MQTT_SEAMBIT_WEB_PASSWORD` ← `dev-mq-seambit-web`

---

## Deploying

### First-time setup

```bash
# Create app (already done — skip if app exists)
flyctl apps create openseam-emqx

# Allocate dedicated public IPv4 (already done — skip if IP already allocated)
flyctl ips allocate-v4 --app openseam-emqx

# Set secrets (one-time — values persist across deployments)
flyctl secrets set \
  EMQX_DASHBOARD__DEFAULT_PASSWORD="..." \
  MQTT_SEAMBIT_CLIENT_PASSWORD="..." \
  MQTT_SEAMBIT_WEB_PASSWORD="..." \
  --app openseam-emqx

# Deploy
./deploy.sh
```

### Subsequent deployments (new EMQX version or bootstrap changes)

```bash
# Update the EMQX version in Dockerfile, then:
./deploy.sh
```

### Verifying the bootstrap ran

```bash
flyctl logs --app openseam-emqx
```

Expected output:
```
[bootstrap] Starting EMQX...
[bootstrap] Waiting for EMQX to become ready (timeout: 120s)...
[bootstrap] EMQX is ready.
[bootstrap] API token acquired.
[bootstrap] User 'seambit-client' created (201).
[bootstrap] User 'seambit-web' created (201).
[bootstrap] All users provisioned. EMQX is operational.
```

---

## EMQX dashboard

The dashboard (port 18083) is internal only — not exposed via Fly.io's proxy. Access via WireGuard tunnel:

```bash
# Open WireGuard tunnel to Fly.io private network
flyctl proxy 18083:18083 --app openseam-emqx

# Then open in browser:
# http://localhost:18083
# Username: admin
# Password: value of EMQX_DASHBOARD__DEFAULT_PASSWORD secret
```

---

## Network / DNS

| Layer | Value |
|---|---|
| Public DNS | `mqtt.seambit.openseam.io` (Squarespace, A record → Fly.io dedicated IPv4) |
| Fly.io app | `openseam-emqx` |
| Fly.io IPv4 | Dedicated — see `flyctl ips list --app openseam-emqx` |
| Internal port | 1883 (MQTT TCP) |

---

## Related repos

| Repo | Relationship |
|---|---|
| `mqtt_broker` | Previous Fargate deployment (decommissioned after migration) |
| `assets/inference` | Subscribes to raw sensor topics — uses `seambit-client` |
| `seambit_status_server` | Subscribes to burst events — uses `seambit-client` |
| `worker_suspected_stoppage` | Subscribes to burst events — uses `seambit-web` |
