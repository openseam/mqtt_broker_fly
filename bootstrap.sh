#!/usr/bin/env bash
# Bootstrap wrapper for EMQX on Fly.io.
# Starts EMQX using the original entrypoint, waits for it to be healthy,
# then creates the two required MQTT users via the HTTP API.
# Users are re-created on every container start — no persistent state required.

set -e

EMQX_API="http://localhost:18083/api/v5"
MAX_WAIT_SECONDS=120
WAIT_INTERVAL=3

log() { echo "[bootstrap] $*"; }

# ── Set file descriptor limit for large numbers of concurrent MQTT connections ─
ulimit -n 1048576 2>/dev/null || log "WARNING: Could not set nofile ulimit to 1048576 — proceeding with system default."

# ── Start EMQX in the background ──────────────────────────────────────────────
log "Starting EMQX..."
/usr/bin/docker-entrypoint.sh "$@" &
EMQX_PID=$!

# ── Wait for EMQX to be ready ─────────────────────────────────────────────────
log "Waiting for EMQX to become ready (timeout: ${MAX_WAIT_SECONDS}s)..."
elapsed=0
until curl -sf "${EMQX_API}/status" 2>/dev/null | grep -q "running"; do
    if (( elapsed >= MAX_WAIT_SECONDS )); then
        log "ERROR: EMQX did not become ready within ${MAX_WAIT_SECONDS}s. Aborting bootstrap."
        kill "$EMQX_PID" 2>/dev/null
        exit 1
    fi
    sleep "$WAIT_INTERVAL"
    elapsed=$(( elapsed + WAIT_INTERVAL ))
done
log "EMQX is ready."

# ── Authenticate with the dashboard API ───────────────────────────────────────
if [[ -z "${EMQX_DASHBOARD__DEFAULT_PASSWORD:-}" ]]; then
    log "ERROR: EMQX_DASHBOARD__DEFAULT_PASSWORD is not set. Cannot provision users."
    wait "$EMQX_PID"
    exit 1
fi

TOKEN=$(curl -sf -X POST "${EMQX_API}/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${EMQX_DASHBOARD__DEFAULT_PASSWORD}\"}" \
    | jq -r '.token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    log "ERROR: Failed to obtain API token. Dashboard password may be incorrect."
    wait "$EMQX_PID"
    exit 1
fi
log "API token acquired."

# ── Provision MQTT users ───────────────────────────────────────────────────────
provision_user() {
    local username="$1"
    local password="$2"

    if [[ -z "$password" ]]; then
        log "ERROR: Password for '${username}' is empty. Skipping."
        return 1
    fi

    local status
    for attempt in 1 2 3; do
        status=$(curl -sf -w "%{http_code}" -o /dev/null \
            -X POST \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            "${EMQX_API}/authentication/password_based%3Abuilt_in_database/users" \
            -d "{\"user_id\":\"${username}\",\"password\":\"${password}\",\"is_superuser\":false}" \
            2>/dev/null)

        if [[ "$status" == "201" ]]; then
            log "User '${username}' created (201)."
            return 0
        elif [[ "$status" == "409" ]]; then
            log "User '${username}' already exists (409) — skipping."
            return 0
        else
            log "Attempt ${attempt}/3 for '${username}' returned HTTP ${status}. Retrying..."
            sleep 3
        fi
    done

    log "ERROR: Failed to provision user '${username}' after 3 attempts."
    return 1
}

PROVISIONING_OK=true
provision_user "seambit-client" "${MQTT_SEAMBIT_CLIENT_PASSWORD}" || PROVISIONING_OK=false
provision_user "seambit-web"    "${MQTT_SEAMBIT_WEB_PASSWORD}"    || PROVISIONING_OK=false

if $PROVISIONING_OK; then
    log "All users provisioned. EMQX is operational."
else
    log "WARNING: One or more users failed to provision. Check secrets MQTT_SEAMBIT_CLIENT_PASSWORD and MQTT_SEAMBIT_WEB_PASSWORD."
fi

# ── Periodic healthchecks.io heartbeat ────────────────────────────────────────
# Pings every 5 minutes so healthchecks.io (10 min period, 2 min grace) stays green.
if [[ -n "${HEARTBEAT_URL:-}" ]]; then
    log "Starting healthchecks.io heartbeat loop (every 5 minutes)."
    (
        while kill -0 "$EMQX_PID" 2>/dev/null; do
            curl -fsS --retry 3 --max-time 10 "${HEARTBEAT_URL}" >/dev/null 2>&1 \
                && log "heartbeat.pinged" \
                || log "WARNING: heartbeat ping failed — will retry in 5 minutes"
            sleep 300
        done
    ) &
else
    log "WARNING: HEARTBEAT_URL not set — healthchecks.io ping disabled."
fi

# ── Keep running until EMQX exits ─────────────────────────────────────────────
wait "$EMQX_PID"
