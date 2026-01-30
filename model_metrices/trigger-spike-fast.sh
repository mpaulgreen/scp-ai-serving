#!/bin/bash
#
# Fast Request Spike Trigger (for testing)
#
# This script triggers VLLMRequestSpike alert using a 15-minute baseline
# Total runtime: ~25 minutes
#
# Usage:
#   chmod +x trigger-spike-fast.sh
#   ./trigger-spike-fast.sh
#
# There is a test limitation of testing this alert.
set -e

echo "========================================="
echo "VLLMRequestSpike Alert Trigger (Fast)"
echo "========================================="
echo ""

# Function to get fresh access token
get_access_token() {
  local token=$(curl -sk -X POST "${KEYCLOAK_URL}/auth/realms/maas/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=maas-client" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "grant_type=client_credentials" 2>/dev/null | jq -r '.access_token')

  if [ -z "$token" ] || [ "$token" == "null" ]; then
    echo "❌ Failed to obtain access token"
    exit 1
  fi

  echo "$token"
}

# Get cluster credentials (only once)
echo "Getting cluster credentials..."
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export KEYCLOAK_URL=https://$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}')
export CLIENT_SECRET=$(oc get secret keycloak-client-secret-maas-client -n rhsso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)
export MODEL_URL="https://maas.${CLUSTER_DOMAIN}/llm/granite-3-1-8b-instruct-fp8"

# Get initial access token
export ACCESS_TOKEN=$(get_access_token)
echo "✅ Access token obtained"
echo ""

# Phase 1: Baseline traffic for 15 minutes (required for 15-min average)
# Rate: 0.1 req/s = 1 req every 10 seconds = 90 requests over 15 min
echo "========================================="
echo "Phase 1: Baseline (15 min)"
echo "========================================="
echo "Sending 90 requests at 1 req/10s (~0.1 req/s)"
echo "This establishes the baseline average"
echo ""

for i in {1..90}; do
  # Refresh token midway through baseline (after ~7.5 min / 45 requests)
  if [ $i -eq 45 ]; then
    echo ""
    echo "🔄 Refreshing token (midway through baseline)..."
    export ACCESS_TOKEN=$(get_access_token)
    echo "✅ Token refreshed"
  fi

  curl -sk "${MODEL_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"granite-3.1-8b-instruct-fp8","messages":[{"role":"user","content":"baseline"}],"max_tokens":10}' \
    > /dev/null 2>&1 && echo -n "." || echo -n "x"

  if [ $((i % 20)) -eq 0 ]; then
    echo " $i/90"
  fi

  sleep 10
done

echo ""
echo "✅ Baseline established (15 min @ 0.1 req/s)"
echo ""

# Refresh token before Phase 2 (baseline took ~15 min, token may be expiring)
echo "🔄 Refreshing access token before spike phase..."
export ACCESS_TOKEN=$(get_access_token)
echo "✅ Fresh token obtained"
echo ""

# Phase 2: Traffic spike for 10+ minutes (required for alert to fire)
# Rate: 0.3 req/s = 1 req every 3.33 seconds = 180 requests over 10 min
# This is 3x the baseline rate
echo "========================================="
echo "Phase 2: Traffic Spike (10 min)"
echo "========================================="
echo "Sending 180 requests at 1 req/3.3s (~0.3 req/s = 3x baseline)"
echo "⚠️  Alert should fire after 10 min of sustained spike"
echo ""

for i in {1..180}; do
  # Refresh token midway through spike phase (after ~5 min / 90 requests)
  if [ $i -eq 90 ]; then
    echo ""
    echo "🔄 Refreshing token (midway through spike)..."
    export ACCESS_TOKEN=$(get_access_token)
    echo "✅ Token refreshed"
  fi

  curl -sk "${MODEL_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"granite-3.1-8b-instruct-fp8","messages":[{"role":"user","content":"spike '$i'"}],"max_tokens":10}' \
    > /dev/null 2>&1 && echo -n "." || echo -n "x"

  if [ $((i % 20)) -eq 0 ]; then
    echo " $i/180"
  fi

  sleep 3.3
done

echo ""
echo "========================================="
echo "Summary"
echo "========================================="
echo "✅ Traffic spike complete!"
echo ""
echo "Timeline:"
echo "  - Phase 1: 15 min baseline @ 0.1 req/s"
echo "  - Phase 2: 10 min spike @ 0.3 req/s (3x)"
echo "  - Total: 25 minutes"
echo ""
echo "Expected behavior:"
echo "  - Alert should be FIRING now"
echo "  - Threshold: 0.1 × 3 = 0.3 req/s"
echo "  - Actual spike: 0.3 req/s"
echo ""
echo "Check alert status:"
echo "  curl -sk -H \"Authorization: Bearer \$(oc whoami -t)\" \\"
echo "    'https://localhost:9091/api/v1/alerts' | \\"
echo "    jq '.data.alerts[] | select(.labels.alertname==\"VLLMRequestSpike\")'"
echo ""
