#!/bin/bash
#
# Test Script for LLM Model Metrics Generation
#
# This script sends 100 test requests to the deployed LLM model
# to generate metrics that will be visible in Prometheus and Grafana.
#
# Prerequisites:
#   - MaaS platform deployed (maas-platform.yaml)
#   - LLM model deployed (granite-3-1-8b-instruct-fp8)
#   - Keycloak authentication configured
#   - Monitoring stack deployed (ServiceMonitor, Grafana)
#
# Usage:
#   chmod +x test-model-metrics.sh
#   ./test-model-metrics.sh
#

set -e

echo "========================================"
echo "LLM Model Metrics Test Script"
echo "========================================"
echo ""

# Get cluster domain
echo "Getting cluster domain..."
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

# Get Keycloak URL
echo "Getting Keycloak URL..."
export KEYCLOAK_URL=https://$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}')
echo "Keycloak URL: ${KEYCLOAK_URL}"
echo ""

# Get client secret
echo "Getting client secret..."
export CLIENT_SECRET=$(oc get secret keycloak-client-secret-maas-client -n rhsso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)
echo "Client secret: [REDACTED]"
echo ""

# Get access token
echo "Obtaining access token from Keycloak..."
export ACCESS_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/auth/realms/maas/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=maas-client" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "grant_type=client_credentials" | jq -r '.access_token')

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
  echo "❌ Failed to obtain access token from Keycloak"
  exit 1
fi

echo "✅ Access token obtained"
echo ""

# Set model URL
export MODEL_URL="https://maas.${CLUSTER_DOMAIN}/llm/granite-3-1-8b-instruct-fp8"
echo "Model URL: ${MODEL_URL}"
echo ""

# Send test requests
echo "========================================"
echo "Sending 100 test requests..."
echo "========================================"
echo ""

SUCCESS_COUNT=0
FAILURE_COUNT=0

for i in {1..100}; do
  RESPONSE=$(curl -sk -w "\n%{http_code}" "${MODEL_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "granite-3.1-8b-instruct-fp8",
      "messages": [{"role": "user", "content": "Hello, this is test request '"${i}"'"}],
      "max_tokens": 50
    }')

  HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

  if [ "$HTTP_CODE" == "200" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    echo -n "✓"
  else
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    echo -n "✗"
  fi

  if [ $((i % 10)) -eq 0 ]; then
    echo " $i requests completed (${SUCCESS_COUNT} success, ${FAILURE_COUNT} failed)"
  fi
done

echo ""
echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo "Total requests sent: 100"
echo "Successful: ${SUCCESS_COUNT}"
echo "Failed: ${FAILURE_COUNT}"
echo ""

# Wait for metrics to be scraped
echo "Waiting 10 seconds for Prometheus to scrape metrics..."
sleep 10
echo ""

# Query Prometheus to verify metrics
echo "========================================"
echo "Verifying Metrics in Prometheus"
echo "========================================"
echo ""

# Check if port-forward is already running
if ! pgrep -f "port-forward.*thanos-querier.*9091:9091" > /dev/null; then
  echo "Starting port-forward to Thanos Querier..."
  oc port-forward -n openshift-monitoring svc/thanos-querier 9091:9091 > /dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  sleep 3
  echo "Port-forward started (PID: ${PORT_FORWARD_PID})"
else
  echo "Port-forward to Thanos Querier already running"
  PORT_FORWARD_PID=""
fi
echo ""

# Get OpenShift token
TOKEN=$(oc whoami -t)

# Query request success total
echo "1. Total successful requests:"
REQUESTS=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/query?query=kserve_vllm:request_success_total{namespace="llm"}' | \
  jq -r '.data.result[0].value[1]' 2>/dev/null)
echo "   kserve_vllm:request_success_total = ${REQUESTS:-0}"
echo ""

# Query average generation throughput
echo "2. Average generation throughput:"
THROUGHPUT=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/query?query=kserve_vllm:avg_generation_throughput_toks_per_s{namespace="llm"}' | \
  jq -r '.data.result[0].value[1]' 2>/dev/null)
echo "   kserve_vllm:avg_generation_throughput_toks_per_s = ${THROUGHPUT:-0} tokens/s"
echo ""

# Query GPU cache usage
echo "3. GPU cache usage:"
GPU_CACHE=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/query?query=kserve_vllm:gpu_cache_usage_perc{namespace="llm"}' | \
  jq -r '.data.result[0].value[1]' 2>/dev/null)
echo "   kserve_vllm:gpu_cache_usage_perc = ${GPU_CACHE:-0}%"
echo ""

# Query active requests
echo "4. Currently running requests:"
RUNNING=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/query?query=kserve_vllm:num_requests_running{namespace="llm"}' | \
  jq -r '.data.result[0].value[1]' 2>/dev/null)
echo "   kserve_vllm:num_requests_running = ${RUNNING:-0}"
echo ""

# Query E2E latency (P95)
echo "5. End-to-end latency (P95):"
LATENCY=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/query?query=histogram_quantile(0.95,rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m]))' | \
  jq -r '.data.result[0].value[1]' 2>/dev/null)
echo "   P95 latency = ${LATENCY:-0}s"
echo ""

# Clean up port-forward if we started it
if [ -n "$PORT_FORWARD_PID" ]; then
  echo "Stopping port-forward (PID: ${PORT_FORWARD_PID})..."
  kill $PORT_FORWARD_PID 2>/dev/null || true
fi

echo ""
echo "========================================"
echo "Next Steps"
echo "========================================"
echo ""
echo "1. View metrics in Prometheus:"
echo "   oc port-forward -n openshift-monitoring svc/thanos-querier 9091:9091"
echo "   Then open: https://localhost:9091"
echo ""
echo "2. View dashboards in Grafana:"
GRAFANA_URL=$(oc get route grafana -n custom-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -n "$GRAFANA_URL" ]; then
  echo "   https://${GRAFANA_URL}"
  echo "   Username: admin"
  echo "   Password: \$(oc get secret grafana-admin -n custom-monitoring -o jsonpath='{.data.password}' | base64 -d)"
else
  echo "   Grafana route not found. Check if Grafana is deployed in custom-monitoring namespace."
fi
echo ""
echo "3. Run more requests to generate additional metrics:"
echo "   ./test-model-metrics.sh"
echo ""
echo "✅ Test completed successfully!"
