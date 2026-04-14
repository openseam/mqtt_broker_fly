#!/usr/bin/env bash
# Deploy EMQX to Fly.io.
# Run from the mqtt_broker_fly directory.
# Requires: flyctl authenticated (fly auth login)

set -e

APP="openseam-emqx"

echo "Deploying ${APP} to Fly.io..."
flyctl deploy --app "$APP" --remote-only

echo ""
echo "Verifying deployment..."
flyctl status --app "$APP"

echo ""
echo "Recent logs:"
flyctl logs --app "$APP" --no-tail 2>/dev/null | tail -30 || true

echo ""
echo "Done. Check logs for bootstrap output:"
echo "  flyctl logs --app ${APP}"
