# LLM Model Monitoring - Operating Instructions

Complete operating instructions for the centralized vLLM monitoring stack on OpenShift AI.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Installation](#installation)
5. [Accessing Grafana](#accessing-grafana)
6. [Using the Dashboards](#using-the-dashboards)
7. [Verification](#verification)
8. [Monitoring Across Namespaces](#monitoring-across-namespaces)
9. [Alerting](#alerting)
10. [Reference](#reference)

---

## Overview

This monitoring stack provides **centralized monitoring across all namespaces** from a single `custom-monitoring` namespace:

### Key Capabilities

- **Cross-Namespace Discovery**: Automatically discovers LLM pods in ANY namespace
- **vLLM Runtime Metrics**: Request latency (TTFT, TPOT, E2E), throughput, token generation rates
- **Business Metrics**: Token consumption, tier-based usage tracking
- **Alerting**: PrometheusRule with 9 alert conditions
- **Scalable Architecture**: Single monitoring stack for all LLM workloads

### Components

- **PodMonitor**: Discovers and scrapes vLLM metrics from all namespaces
- **Prometheus**: Stores time-series metrics (OpenShift user-workload monitoring)
- **Grafana**: Visualization with 2 dashboards (performance and business metrics)
- **PrometheusRule**: Alert definitions for critical conditions

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      Multiple Namespaces                          │
│                                                                   │
│  Namespace: llm              Namespace: production               │
│  ┌─────────────────┐         ┌─────────────────┐                │
│  │ LLM Pod         │         │ LLM Pod         │                │
│  │ granite-3.1-8b  │         │ granite-8b-prod │                │
│  │ /metrics        │         │ /metrics        │                │
│  └─────────────────┘         └─────────────────┘                │
└──────────────┬────────────────────────┬──────────────────────────┘
               │                        │
               │ Discovered by PodMonitor (label selector)
               │                        │
               └────────────┬───────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│              Namespace: custom-monitoring                         │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  PodMonitor: vllm-metrics                                 │   │
│  │  - namespaceSelector: any (ALL namespaces)                │   │
│  │  - Scrapes :8000/metrics every 30s                        │   │
│  │  - Adds labels: namespace, model_name, pod                │   │
│  └───────────────────────────────────────────────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  Prometheus (OpenShift User Workload Monitoring)          │   │
│  │  - Stores metrics from all namespaces                     │   │
│  │  - Evaluates PrometheusRule alerts                         │   │
│  └───────────────────────────────────────────────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  Grafana (Dashboards with namespace filter)               │   │
│  │  - vLLM Performance Dashboard                             │   │
│  │  - Business Metrics Dashboard                             │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  PrometheusRule: vllm-alerts                               │   │
│  │  - Monitors all namespaces                                │   │
│  └───────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### Design Principles

1. **Centralized**: Single monitoring stack in `custom-monitoring` namespace
2. **Automatic Discovery**: PodMonitor discovers pods by label across all namespaces
3. **Namespace Isolation**: Metrics include namespace labels for filtering
4. **No Per-Namespace Setup**: Deploy models anywhere - automatically monitored

---

## Prerequisites

### Required

- OpenShift 4.12+ with user-workload monitoring enabled
- LLM models deployed with vLLM runtime via LLMInferenceService
- `oc` CLI authenticated as cluster-admin or with monitoring permissions
- `jq` installed for JSON processing

### Platform Deployment

Before setting up monitoring, ensure the MAAS platform and LLM models are deployed:

1. **Deploy MAAS Platform**: Follow `../oauth_poc/README.md` up to (but excluding) the "Test Model Inference" section to set up the base platform with authentication
2. **Deploy Granite Model**: Follow `../modelcar/large_model.md` to deploy the granite-3.1-8b-instruct model with vLLM runtime

### Enable User Workload Monitoring

If not already enabled:

```bash
# Enable user workload monitoring
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

# Verify monitoring pods are running
oc get pods -n openshift-user-workload-monitoring

# Wait for pods to be ready (may take 2-3 minutes)
oc wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus \
  -n openshift-user-workload-monitoring --timeout=300s
```

---

## Installation

Follow these steps to deploy the monitoring stack in the `custom-monitoring` namespace.

### Step 1: Create Monitoring Namespace

```bash
# Create dedicated monitoring namespace
oc create namespace custom-monitoring

# Verify
oc get namespace custom-monitoring
```

**Expected output**:
```
NAME                 STATUS   AGE
custom-monitoring    Active   5s
```

### Step 2: Deploy PodMonitor

The PodMonitor discovers and scrapes vLLM metrics from LLM pods across all namespaces.

```bash
# Deploy PodMonitor
oc apply -f podmonitor-vllm.yaml

# Verify
oc get podmonitor -n custom-monitoring
```

**Expected output**:
```
NAME           AGE
vllm-metrics   10s
```

**What it does**:
- Discovers pods with label `app.kubernetes.io/part-of: llminferenceservice`
- Scrapes `/metrics` endpoint on port 8000 every 30 seconds
- Works across ALL namespaces (`namespaceSelector.any: true`)

### Step 3: Deploy PrometheusRule

The PrometheusRule defines alert conditions for monitoring.

```bash
# Deploy alert rules
oc apply -f prometheus-alerts.yaml

# Verify
oc get prometheusrule -n llm
```

**Expected output**:
```
NAME          AGE
vllm-alerts   10s
```

**Alerts included**: 9 alerts covering performance, reliability, and capacity issues.

### Step 4: Deploy Grafana

Deploy Grafana with all necessary configurations including:
- ServiceAccount and token for Prometheus authentication
- ClusterRoleBinding for read access to metrics across all namespaces
- Grafana deployment, service, route, and persistent storage

```bash
# Deploy Grafana (includes ServiceAccount, Secret, RBAC, Deployment, etc.)
oc apply -f grafana-deployment.yaml

# Wait for Grafana to be ready (may take 2-3 minutes)
oc wait --for=condition=Available deployment/grafana -n custom-monitoring --timeout=300s

# Verify pod is running
oc get pods -n custom-monitoring -l app=grafana

# Verify RBAC is configured
oc get serviceaccount grafana -n custom-monitoring
oc get secret grafana-token -n custom-monitoring
oc get clusterrolebinding grafana-prometheus-reader
```

**Expected output**:
```
NAME                       READY   STATUS    RESTARTS   AGE
grafana-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

### Step 5: Configure Grafana Datasource

Configure Grafana to query Prometheus via Thanos Querier.

```bash
# Get required information
GRAFANA_POD=$(oc get pods -n custom-monitoring -l app=grafana -o jsonpath='{.items[0].metadata.name}')
GRAFANA_PASSWORD=$(oc get secret grafana-admin -n custom-monitoring -o jsonpath='{.data.password}' | base64 -d)
SA_TOKEN=$(oc get secret grafana-token -n custom-monitoring -o jsonpath='{.data.token}' | base64 -d)

# Create Prometheus datasource with UID "prometheus"
oc exec -n custom-monitoring $GRAFANA_POD -- curl -s -X POST \
  -H "Content-Type: application/json" \
  -u "admin:${GRAFANA_PASSWORD}" \
  http://localhost:3000/api/datasources \
  -d '{
    "uid": "prometheus",
    "name": "Prometheus",
    "type": "prometheus",
    "access": "proxy",
    "url": "https://thanos-querier.openshift-monitoring.svc.cluster.local:9091",
    "basicAuth": false,
    "isDefault": true,
    "jsonData": {
      "httpHeaderName1": "Authorization",
      "tlsSkipVerify": true,
      "timeInterval": "30s"
    },
    "secureJsonData": {
      "httpHeaderValue1": "Bearer '"$SA_TOKEN"'"
    }
  }' 2>/dev/null | jq '{id, uid, name}'
```

**Expected output**:
```json
{
  "id": 1,
  "name": "Prometheus"
}
```

**Important**: The UID must be "prometheus" for dashboards to work correctly.

### Step 6: Import Dashboards

Import the vLLM Performance and Business Metrics dashboards.

```bash
# Import vLLM Performance Dashboard
DASHBOARD_JSON=$(cat grafana-dashboard-vllm-performance.json | jq '{
  dashboard: .,
  overwrite: true,
  message: "Initial import"
}')

oc exec -n custom-monitoring $GRAFANA_POD -- curl -s -X POST \
  -H "Content-Type: application/json" \
  -u "admin:${GRAFANA_PASSWORD}" \
  "http://localhost:3000/api/dashboards/db" \
  -d "$DASHBOARD_JSON" 2>/dev/null | jq '{status, uid}'

# Import Business Metrics Dashboard
DASHBOARD_JSON=$(cat grafana-dashboard-business.json | jq '{
  dashboard: .,
  overwrite: true,
  message: "Initial import"
}')

oc exec -n custom-monitoring $GRAFANA_POD -- curl -s -X POST \
  -H "Content-Type: application/json" \
  -u "admin:${GRAFANA_PASSWORD}" \
  "http://localhost:3000/api/dashboards/db" \
  -d "$DASHBOARD_JSON" 2>/dev/null | jq '{status, uid}'
```

**Expected output** (for each dashboard):
```json
{
  "status": "success",
  "uid": "vllm-performance"
}
```

---

## Accessing Grafana

### Get Access Credentials

```bash
# Get Grafana URL
GRAFANA_URL=$(oc get route grafana -n custom-monitoring -o jsonpath='{.spec.host}')

# Get admin password
GRAFANA_PASSWORD=$(oc get secret grafana-admin -n custom-monitoring -o jsonpath='{.data.password}' | base64 -d)

# Display credentials
echo "============================================"
echo "Grafana Access Information"
echo "============================================"
echo "URL:      https://${GRAFANA_URL}"
echo "Username: admin"
echo "Password: ${GRAFANA_PASSWORD}"
echo "============================================"
```

### Login

1. Open the URL in your browser
2. Login with username `admin` and the password from above
3. Navigate to Dashboards → Browse to see available dashboards

---

## Using the Dashboards

### 1. vLLM Performance Dashboard

**Purpose**: Monitor LLM inference performance metrics

**Key Panels**:
- **Request Rate**: Requests per second split by completion reason (stop vs length-limited)
- **Success Rate**: Percentage of successful requests (always 100% - no failure metrics tracked)
- **Active Requests**: Currently running, waiting, and swapped requests
- **Latency Percentiles**: TTFT, TPOT, and E2E latency (P50/P95/P99)
- **Token Throughput**: Input and output tokens per second
- **GPU KV Cache Usage**: Cache utilization percentage
- **Preemptions**: Request preemption events per minute
- **Total Tokens**: Cumulative input and output token counts

**Namespace Filter**:
- Use the dropdown at the top to filter by namespace
- Select "All" to view aggregate metrics across all namespaces
- Select specific namespace (e.g., "llm", "production") to focus on one environment

**Use Cases**:
- Monitor real-time inference performance
- Identify latency bottlenecks (TTFT vs TPOT)
- Detect queue buildup before it impacts users
- Compare performance across namespaces

### 2. Business Metrics Dashboard

**Purpose**: Track usage, costs, and business metrics

**Key Panels**:
- **Requests by Model (Last Hour)**: Request distribution across models
- **Request Rate by Model**: Real-time request rate trends per model
- **Token Consumption by Model (Hourly)**: Input and output token usage by model
- **Total Tokens (24h)**: Sum of all tokens processed in last 24 hours
- **Estimated Cost (24h)**: Cost calculation based on token consumption @ $0.02/1K tokens
- **Request Queue Depth by Model**: Number of requests waiting in queue
- **Peak Usage Heatmap**: Request rate heatmap by hour of day
- **Top Models by Request Count (24h)**: Most frequently used models
- **Top 20 Users by Token Consumption (24h)**: Highest token consumers (requires user tracking)
- **Request Success vs Failure (Hourly)**: Successful vs failed request counts (failure always 0 - no failure metrics)

**Namespace Filter**:
- Same as Performance Dashboard
- Filter by namespace to see usage per environment

**Use Cases**:
- Usage analytics and billing
- Model-level capacity planning
- Cost estimation and chargeback
- Identify heavy users and high-traffic models
- Detect usage patterns by time of day

---

## Verification

### Verify PodMonitor is Discovering Pods

```bash
# Check PodMonitor exists
oc get podmonitor vllm-metrics -n custom-monitoring

# Verify pods have the correct label
oc get pods -n llm -l app.kubernetes.io/part-of=llminferenceservice \
  -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace

# Verify metrics are being scraped (wait 30s after PodMonitor creation)
TOKEN=$(oc whoami -t)

# Port-forward to Thanos Querier if not already running
if ! pgrep -f "port-forward.*thanos-querier.*9091" > /dev/null 2>&1; then
  oc port-forward -n openshift-monitoring svc/thanos-querier 9091:9091 > /dev/null 2>&1 &
  sleep 3
fi

# Query for vLLM metrics to verify scraping is working
curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/query?query=kserve_vllm:request_success_total' 2>/dev/null | \
  jq -r '.data.result[0].metric | "Pod: \(.pod) | Namespace: \(.namespace) | Model: \(.model_name)"'
```

**Expected output:**
```
NAME                                                  NAMESPACE
granite-3-1-8b-instruct-fp8-kserve-7b9846d9dd-xxxxx   llm

Pod: granite-3-1-8b-instruct-fp8-kserve-xxxxx | Namespace: llm | Model: granite-3-1-8b-instruct-fp8
```

If you see the pod name and metrics, the PodMonitor is working correctly!

### Verify Metrics are Being Scraped

Use the validation script to check metrics:

```bash
./validate-metrics.sh
```

**Expected output**:
```
Connected to Prometheus
Model pod is running in llm namespace: granite-3-1-8b-instruct-fp8-xxxxx
PodMonitor exists in custom-monitoring namespace
PrometheusRule exists in llm namespace
Grafana is running: https://grafana-custom-monitoring.apps...
Total requests: 102
Average TTFT: 0.02s
Average E2E: 0.96s
GPU cache: 0%
```

### Generate Test Traffic

Generate test requests to populate metrics:

```bash
./test-model-metrics.sh

# Wait 1 minute for metrics to be scraped
sleep 60

# Check Grafana dashboards - you should see:
# - Request rate increasing
# - Latency metrics updating
# - Token throughput visible
```

---

## Monitoring Across Namespaces

The PodMonitor automatically discovers LLM pods in **any namespace**. No configuration changes needed!

### How It Works

1. **PodMonitor** uses `namespaceSelector.any: true` to discover pods everywhere
2. **Label Selector**: Matches pods with `app.kubernetes.io/part-of: llminferenceservice`
3. **Automatic Discovery**: New pods are discovered within 30 seconds
4. **Namespace Labels**: All metrics include `namespace` label for filtering

### Example: Deploy Model in New Namespace

```bash
# Create new namespace
oc create namespace production

# Deploy your LLMInferenceService
oc apply -f my-llm-model.yaml -n production

# Wait for pod to be ready
oc wait --for=condition=Ready pod \
  -l app.kubernetes.io/part-of=llminferenceservice \
  -n production --timeout=300s

# Metrics automatically appear in Grafana!
# Use namespace filter to view "production" namespace metrics
```

### Viewing Metrics by Namespace

In Grafana dashboards:
1. Look for the **Namespace** dropdown variable at the top
2. Select:
   - Specific namespace (e.g., `llm`, `production`) to focus on one environment
   - `All` to aggregate metrics across all namespaces
3. All panels update automatically based on selection


---

## Alerting

The monitoring stack includes 9 pre-configured alerts that monitor across all namespaces.

### Alert List

| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| VLLMHighLatency | P95 E2E > 10s | warning | Slow inference responses |
| VLLMHighTimeToFirstToken | P95 TTFT > 5s | warning | Slow first token generation |
| VLLMLowTokenThroughput | Throughput < 50 tok/s | warning | Low token generation rate |
| VLLMNoRequests | No requests 10min | warning | No activity detected |
| VLLMHighQueueDepth | Waiting > 50 | warning | Request backlog building |
| VLLMGPUCacheFull | GPU cache > 95% | warning | Memory pressure |
| VLLMFrequentPreemptions | Preemptions > 10/min | warning | Capacity issues |
| VLLMRequestSpike | 3x normal rate (15min baseline) | info | Traffic spike detected |
| VLLMExcessiveTokenUsage | Token gen rate > 1M tok/s (1h avg) | info | Excessive token usage |

### Viewing Alerts

```bash
# View alert rules definition
oc get prometheusrule vllm-alerts -n llm -o yaml

# Check alert status via Thanos Querier
TOKEN=$(oc whoami -t)

# Port-forward to Thanos Querier if not already running
if ! pgrep -f "port-forward.*thanos-querier.*9091" > /dev/null 2>&1; then
  oc port-forward -n openshift-monitoring svc/thanos-querier 9091:9091 > /dev/null 2>&1 &
  sleep 3
fi

# View all vLLM alerts and their states
curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/rules' 2>/dev/null | \
  jq -r '.data.groups[] | select(.name | contains("vllm")) |
    .rules[] |
    select(.type=="alerting") |
    {
      alert: .name,
      state: .state,
      duration: .duration,
      labels: .labels
    }'

# View only FIRING alerts
curl -sk -H "Authorization: Bearer $TOKEN" \
  'https://localhost:9091/api/v1/alerts' 2>/dev/null | \
  jq -r '.data.alerts[] |
    select(.labels.component=="vllm") |
    {
      alert: .labels.alertname,
      severity: .labels.severity,
      namespace: .labels.namespace,
      model: .labels.model_name,
      state: .state,
      value: .value
    }'
```

**Alert States:**
- `inactive` - Condition is false (healthy)
- `pending` - Condition true, waiting for `for` duration
- `firing` - Alert is active

### Alert Labels

All alerts include:
- `namespace`: Which namespace triggered the alert
- `severity`: critical, warning, or info
- `component`: vllm
- `alert_type`: performance, reliability, capacity, or business

### Customizing Alerts

Edit alert thresholds:

```bash
# Edit PrometheusRule
oc edit prometheusrule vllm-alerts -n llm

# Example: Change high latency threshold from 10s to 5s
# Find: kserve_vllm:e2e_request_latency_seconds_bucket) > 10
# Change to: kserve_vllm:e2e_request_latency_seconds_bucket) > 5

# Save and exit - changes apply immediately
```

---


### Cleanup and Uninstall

- See [CLEANUP.md](CLEANUP.md) for complete uninstall instructions.



---

## Reference

### Key Metrics (kserve_vllm: prefix)

#### Request Metrics
- `kserve_vllm:request_success_total` - Successful requests
- `kserve_vllm:num_requests_running` - Currently executing
- `kserve_vllm:num_requests_waiting` - Queued requests
- `kserve_vllm:num_requests_swapped` - Swapped to CPU memory

#### Latency Metrics (Histograms)
- `kserve_vllm:time_to_first_token_seconds_bucket` - TTFT latency
- `kserve_vllm:time_per_output_token_seconds_bucket` - TPOT latency
- `kserve_vllm:e2e_request_latency_seconds_bucket` - End-to-end latency

#### Token Metrics
- `kserve_vllm:prompt_tokens_total` - Input tokens processed
- `kserve_vllm:generation_tokens_total` - Output tokens generated

#### GPU/Cache Metrics
- `kserve_vllm:gpu_cache_usage_perc` - GPU KV cache usage
- `kserve_vllm:cpu_cache_usage_perc` - CPU cache usage
- `kserve_vllm:gpu_prefix_cache_hit_rate` - Cache hit rate
- `kserve_vllm:num_preemptions_total` - Request preemptions

#### Throughput Metrics
- `kserve_vllm:avg_prompt_throughput_toks_per_s` - Input throughput
- `kserve_vllm:avg_generation_throughput_toks_per_s` - Output throughput

### Files Reference

**Deployment Files**:
- `podmonitor-vllm.yaml` - Cross-namespace pod discovery and scraping
- `prometheus-alerts.yaml` - Alert rules for all namespaces
- `grafana-deployment.yaml` - Grafana in custom-monitoring namespace

**Dashboards**:
- `grafana-dashboard-vllm-performance.json` - Performance metrics with namespace filter
- `grafana-dashboard-business.json` - Business metrics with namespace filter

**Utility Scripts**:
- `validate-metrics.sh` - Validation tool
- `test-model-metrics.sh` - Generate test traffic

**Documentation**:
- `README.md` - This file (complete operating instructions)
- `CLEANUP.md` - Complete cleanup guide
- `promql-queries.md` - PromQL query reference

