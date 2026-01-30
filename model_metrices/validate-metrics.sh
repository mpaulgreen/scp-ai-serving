#!/bin/bash
#
# Metrics Validation Script for vLLM Monitoring
#
# This script validates that the monitoring stack is working correctly
# and displays key metrics from the deployed LLM model.
#
# Prerequisites:
#   - Monitoring stack deployed (ServiceMonitor, PrometheusRule)
#   - LLM model running (granite-3-1-8b-instruct-fp8)
#   - Port-forward to Thanos Querier running on port 9091
#
# Usage:
#   chmod +x validate-metrics.sh
#   ./validate-metrics.sh
#

# Removed "set -e" to prevent script from exiting on individual command failures
# We want to collect as much information as possible even if some queries fail

echo "========================================"
echo "vLLM Metrics Validation Script"
echo "========================================"
echo ""

# Check if port-forward is running
echo "Checking Thanos Querier connection..."
if ! pgrep -f "port-forward.*thanos-querier.*9091" > /dev/null; then
  echo "⚠️  Port-forward to Thanos Querier not detected"
  echo "Starting port-forward in background..."
  oc port-forward -n openshift-monitoring svc/thanos-querier 9091:9091 > /dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  sleep 3
  echo "✅ Port-forward started (PID: ${PORT_FORWARD_PID})"
else
  echo "✅ Port-forward already running"
  PORT_FORWARD_PID=""
fi
echo ""

# Get OpenShift token
TOKEN=$(oc whoami -t)

# Test connection
echo "Testing Prometheus connection..."
STATUS=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/query?query=up' 2>/dev/null | jq -r '.status' 2>/dev/null)

if [ "$STATUS" != "success" ]; then
  echo "❌ Failed to connect to Prometheus"
  echo "Make sure port-forward is running: oc port-forward -n openshift-monitoring svc/thanos-querier 9091:9091"
  exit 1
fi
echo "✅ Connected to Prometheus successfully"
echo ""

# Function to query metric with timeout
query_metric() {
  local query="$1"
  curl -sk --max-time 10 -H "Authorization: Bearer $TOKEN" \
    "https://localhost:9091/api/v1/query?query=${query}" 2>/dev/null
}

# Function to extract single value
get_value() {
  echo "$1" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0"
}

# Function to format numbers
format_number() {
  local num=$1
  printf "%.2f" "$num" 2>/dev/null || echo "$num"
}

# Function to divide two numbers
divide_numbers() {
  local numerator=$1
  local denominator=$2
  if [ "$denominator" == "0" ] || [ -z "$denominator" ]; then
    echo "0"
  else
    awk "BEGIN {printf \"%.6f\", $numerator / $denominator}"
  fi
}

echo "========================================"
echo "vLLM Performance Metrics"
echo "========================================"
echo ""

# 1. Request Metrics
echo "📊 Request Metrics"
echo "-------------------"

RESULT=$(query_metric 'sum(kserve_vllm:request_success_total)')
TOTAL_REQUESTS=$(get_value "$RESULT")
echo "Total successful requests: ${TOTAL_REQUESTS}"

RESULT=$(query_metric 'kserve_vllm:request_success_total')
echo ""
echo "Breakdown by finish reason:"
echo "$RESULT" | jq -r '.data.result[] | "  - \(.metric.finished_reason): \(.value[1])"' 2>/dev/null || echo "  No data"

RESULT=$(query_metric 'kserve_vllm:num_requests_running')
RUNNING=$(get_value "$RESULT")
echo ""
echo "Currently running requests: ${RUNNING}"

RESULT=$(query_metric 'kserve_vllm:num_requests_waiting')
WAITING=$(get_value "$RESULT")
echo "Requests waiting in queue: ${WAITING}"

echo ""
echo "🚀 Throughput Metrics"
echo "-------------------"

RESULT=$(query_metric 'kserve_vllm:avg_generation_throughput_toks_per_s')
GEN_THROUGHPUT=$(get_value "$RESULT")
GEN_THROUGHPUT_FMT=$(format_number "$GEN_THROUGHPUT")
echo "Avg generation throughput: ${GEN_THROUGHPUT_FMT} tokens/s"

RESULT=$(query_metric 'kserve_vllm:avg_prompt_throughput_toks_per_s')
PROMPT_THROUGHPUT=$(get_value "$RESULT")
PROMPT_THROUGHPUT_FMT=$(format_number "$PROMPT_THROUGHPUT")
echo "Avg prompt throughput: ${PROMPT_THROUGHPUT_FMT} tokens/s"

RESULT=$(query_metric 'sum(kserve_vllm:prompt_tokens_total)')
PROMPT_TOKENS=$(get_value "$RESULT")
echo "Total prompt tokens processed: ${PROMPT_TOKENS}"

RESULT=$(query_metric 'sum(kserve_vllm:generation_tokens_total)')
GENERATION_TOKENS=$(get_value "$RESULT")
echo "Total generation tokens: ${GENERATION_TOKENS}"

echo ""
echo "⏱️  Latency Metrics"
echo "-------------------"

# Time to First Token - Average only (percentiles can be slow)
echo -n "Querying TTFT metrics... "
RESULT=$(query_metric 'sum(kserve_vllm:time_to_first_token_seconds_sum)')
TTFT_SUM=$(get_value "$RESULT")
RESULT=$(query_metric 'sum(kserve_vllm:time_to_first_token_seconds_count)')
TTFT_COUNT=$(get_value "$RESULT")

if [ "$TTFT_COUNT" != "0" ] && [ "$TTFT_COUNT" != "null" ] && [ -n "$TTFT_COUNT" ]; then
  TTFT_AVG=$(divide_numbers "$TTFT_SUM" "$TTFT_COUNT")
  TTFT_AVG_FMT=$(format_number "$TTFT_AVG")
else
  TTFT_AVG_FMT="N/A"
fi
echo "done"

# Time per Output Token - Average only
echo -n "Querying TPOT metrics... "
RESULT=$(query_metric 'sum(kserve_vllm:time_per_output_token_seconds_sum)')
TPOT_SUM=$(get_value "$RESULT")
RESULT=$(query_metric 'sum(kserve_vllm:time_per_output_token_seconds_count)')
TPOT_COUNT=$(get_value "$RESULT")

if [ "$TPOT_COUNT" != "0" ] && [ "$TPOT_COUNT" != "null" ] && [ -n "$TPOT_COUNT" ]; then
  TPOT_AVG=$(divide_numbers "$TPOT_SUM" "$TPOT_COUNT")
  TPOT_AVG_FMT=$(format_number "$TPOT_AVG")
else
  TPOT_AVG_FMT="N/A"
fi
echo "done"

# End-to-end latency - Average only
echo -n "Querying E2E latency metrics... "
RESULT=$(query_metric 'sum(kserve_vllm:e2e_request_latency_seconds_sum)')
E2E_SUM=$(get_value "$RESULT")
RESULT=$(query_metric 'sum(kserve_vllm:e2e_request_latency_seconds_count)')
E2E_COUNT=$(get_value "$RESULT")

if [ "$E2E_COUNT" != "0" ] && [ "$E2E_COUNT" != "null" ] && [ -n "$E2E_COUNT" ]; then
  E2E_AVG=$(divide_numbers "$E2E_SUM" "$E2E_COUNT")
  E2E_AVG_FMT=$(format_number "$E2E_AVG")
else
  E2E_AVG_FMT="N/A"
fi
echo "done"

echo ""
echo "Time to First Token (TTFT):"
echo "  - Average: ${TTFT_AVG_FMT}s"
echo ""
echo "Time per Output Token (TPOT):"
echo "  - Average: ${TPOT_AVG_FMT}s"
echo ""
echo "End-to-End Latency:"
echo "  - Average: ${E2E_AVG_FMT}s"
echo ""
echo "Note: For percentiles (P50, P95, P99), use Grafana dashboards or manual Prometheus queries"

echo ""
echo "========================================"
echo "Infrastructure Metrics"
echo "========================================"
echo ""

echo "💾 GPU/Cache Metrics"
echo "-------------------"

RESULT=$(query_metric 'kserve_vllm:gpu_cache_usage_perc')
GPU_CACHE=$(get_value "$RESULT")
GPU_CACHE_FMT=$(format_number "$GPU_CACHE")
echo "GPU cache usage: ${GPU_CACHE_FMT}%"

RESULT=$(query_metric 'kserve_vllm:cpu_cache_usage_perc')
CPU_CACHE=$(get_value "$RESULT")
CPU_CACHE_FMT=$(format_number "$CPU_CACHE")
echo "CPU cache usage: ${CPU_CACHE_FMT}%"

RESULT=$(query_metric 'kserve_vllm:gpu_prefix_cache_hit_rate')
GPU_HIT_RATE=$(get_value "$RESULT")
GPU_HIT_RATE_FMT=$(format_number "$GPU_HIT_RATE")
echo "GPU prefix cache hit rate: ${GPU_HIT_RATE_FMT}"

RESULT=$(query_metric 'sum(kserve_vllm:num_preemptions_total)')
PREEMPTIONS=$(get_value "$RESULT")
echo "Total preemptions: ${PREEMPTIONS}"

echo ""
echo "🎯 Model Information"
echo "-------------------"

RESULT=$(query_metric 'kserve_vllm:cache_config_info')
echo "$RESULT" | jq -r '.data.result[0].metric | "Model: \(.model_name)\nBlock size: \(.block_size)\nGPU memory utilization: \(.gpu_memory_utilization)\nMax model length: \(.max_model_len)"' 2>/dev/null || echo "No cache config info available"

echo ""
echo "========================================"
echo "Health Check"
echo "========================================"
echo ""

# Check if model pod is running (checking llm namespace as example)
POD_STATUS=$(oc get pods -n llm -l app.kubernetes.io/name=granite-3-1-8b-instruct-fp8 -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
POD_NAME=$(oc get pods -n llm -l app.kubernetes.io/name=granite-3-1-8b-instruct-fp8 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
POD_READY=$(oc get pods -n llm -l app.kubernetes.io/name=granite-3-1-8b-instruct-fp8 -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)

if [ "$POD_STATUS" == "Running" ] && [ "$POD_READY" == "true" ]; then
  echo "✅ Model pod is running in llm namespace: ${POD_NAME}"
elif [ "$POD_STATUS" == "Running" ]; then
  echo "⚠️  Model pod running but not ready in llm namespace: ${POD_NAME}"
elif [ -n "$POD_NAME" ]; then
  echo "❌ Model pod status in llm namespace: ${POD_STATUS} (${POD_NAME})"
else
  echo "ℹ️  No model pod found in llm namespace (PodMonitor will discover pods in any namespace)"
fi

# Check PodMonitor (in custom-monitoring namespace)
PM_EXISTS=$(oc get podmonitor vllm-metrics -n custom-monitoring -o name 2>/dev/null)
if [ -n "$PM_EXISTS" ]; then
  echo "✅ PodMonitor exists in custom-monitoring namespace"
else
  echo "❌ PodMonitor not found in custom-monitoring namespace"
fi

# Check PrometheusRule (in llm namespace)
PR_EXISTS=$(oc get prometheusrule vllm-alerts -n llm -o name 2>/dev/null)
if [ -n "$PR_EXISTS" ]; then
  echo "✅ PrometheusRule exists in llm namespace"
else
  echo "⚠️  PrometheusRule not found in llm namespace"
fi

# Check Grafana (in custom-monitoring namespace)
GRAFANA_STATUS=$(oc get deployment grafana -n custom-monitoring -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
if [ "$GRAFANA_STATUS" == "True" ]; then
  GRAFANA_URL=$(oc get route grafana -n custom-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
  echo "✅ Grafana is running: https://${GRAFANA_URL}"
else
  echo "⚠️  Grafana not available in custom-monitoring namespace"
fi

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo ""

if [ "$TOTAL_REQUESTS" != "0" ] && [ "$TOTAL_REQUESTS" != "null" ]; then
  echo "✅ Monitoring stack is OPERATIONAL"
  echo ""
  echo "Key Stats:"
  echo "  • Total requests: ${TOTAL_REQUESTS}"
  echo "  • Avg TTFT: ${TTFT_AVG_FMT}s"
  echo "  • Avg TPOT: ${TPOT_AVG_FMT}s"
  echo "  • Avg E2E latency: ${E2E_AVG_FMT}s"
  echo "  • GPU cache usage: ${GPU_CACHE_FMT}%"
  echo "  • Total tokens: ${PROMPT_TOKENS} prompt + ${GENERATION_TOKENS} generation"
else
  echo "⚠️  No request data found"
  echo ""
  echo "This could mean:"
  echo "  1. No requests have been sent to the model yet"
  echo "  2. Metrics haven't been scraped yet (wait ~30 seconds)"
  echo ""
  echo "To generate test traffic, run:"
  echo "  ./test-model-metrics.sh"
fi

echo ""
echo "========================================"
echo "Next Steps"
echo "========================================"
echo ""
echo "1. View detailed metrics in Grafana:"
if [ -n "$GRAFANA_URL" ]; then
  echo "   https://${GRAFANA_URL}"
  echo "   Username: admin"
  echo "   Password: \$(oc get secret grafana-admin -n custom-monitoring -o jsonpath='{.data.password}' | base64 -d)"
else
  echo "   (Grafana not deployed in custom-monitoring namespace)"
fi
echo ""
echo "2. Query Prometheus directly:"
echo "   https://localhost:9091"
echo ""
echo "3. Generate more test traffic:"
echo "   /Users/mrigankapaul/Documents/knowledgebase/gori_deliverables/maas/test-model-metrics.sh"
echo ""

# Cleanup port-forward if we started it
if [ -n "$PORT_FORWARD_PID" ]; then
  echo "Note: Port-forward is running in background (PID: ${PORT_FORWARD_PID})"
  echo "To stop it: kill ${PORT_FORWARD_PID}"
fi

echo ""

# Exit successfully
exit 0
