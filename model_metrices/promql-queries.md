# PromQL Query Reference for vLLM Monitoring

This document contains useful PromQL queries for monitoring vLLM-based LLM inference workloads.

## Important Notes

**Available Metrics**:
- `kserve_vllm:request_success_total` - Successful requests (with `finished_reason` label)
- `kserve_vllm:*_latency_*` - Latency histograms (TTFT, TPOT, E2E)
- `kserve_vllm:num_requests_*` - Active/waiting/swapped requests
- `kserve_vllm:*_tokens_total` - Token counters
- `kserve_vllm:*_throughput_*` - Throughput gauges
- `kserve_vllm:*_cache_*` - GPU/CPU cache metrics
- `DCGM_FI_DEV_*` - GPU metrics (in nvidia-gpu-operator namespace)

**NOT Available**:
- `kserve_vllm:request_failure_total` - Metric does not exist
- `istio_requests_total` - No Istio service mesh deployed
- `tier` label - Not applicable to this deployment
- `user` label - Requires custom instrumentation

**Available Labels**: `namespace`, `pod`, `model_name`, `finished_reason` (stop/length), `llm_isvc_name`

## Table of Contents

1. [Request Metrics](#request-metrics)
2. [Latency Metrics](#latency-metrics)
3. [Throughput Metrics](#throughput-metrics)
4. [Resource Metrics](#resource-metrics)
5. [Business Metrics](#business-metrics)
6. [Troubleshooting Queries](#troubleshooting-queries)

---

## Request Metrics

### Request Rate (Requests per second)

```promql
# Request rate (all successful requests)
rate(kserve_vllm:request_success_total{namespace="llm"}[5m])

# Request rate by model
sum by (model_name) (
  rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
)

# Request rate by finished_reason (stop vs length)
sum by (finished_reason) (
  rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
)
```

### Request Distribution by Finish Reason

```promql
# Percentage of requests finishing by reason (stop vs length)
sum by (finished_reason) (
  rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
) /
sum(
  rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
) * 100

# Total requests by finish reason (last hour)
sum by (finished_reason) (
  increase(kserve_vllm:request_success_total{namespace="llm"}[1h])
)
```

### Active Requests

```promql
# Currently running requests
kserve_vllm:num_requests_running{namespace="llm"}

# Requests waiting in queue
kserve_vllm:num_requests_waiting{namespace="llm"}

# Requests swapped to CPU memory
kserve_vllm:num_requests_swapped{namespace="llm"}

# Total active requests (running + waiting + swapped)
kserve_vllm:num_requests_running{namespace="llm"} +
kserve_vllm:num_requests_waiting{namespace="llm"} +
kserve_vllm:num_requests_swapped{namespace="llm"}
```

### Total Requests Over Time

```promql
# Total successful requests in last hour
increase(kserve_vllm:request_success_total{namespace="llm"}[1h])

# Total successful requests in last 24 hours
increase(kserve_vllm:request_success_total{namespace="llm"}[24h])

# Total requests by model (last hour)
sum by (model_name) (
  increase(kserve_vllm:request_success_total{namespace="llm"}[1h])
)
```

---

## Latency Metrics

### Time to First Token (TTFT)

```promql
# P50 TTFT
histogram_quantile(0.50,
  rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace="llm"}[5m])
)

# P95 TTFT
histogram_quantile(0.95,
  rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace="llm"}[5m])
)

# P99 TTFT
histogram_quantile(0.99,
  rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace="llm"}[5m])
)

# Average TTFT
rate(kserve_vllm:time_to_first_token_seconds_sum{namespace="llm"}[5m]) /
rate(kserve_vllm:time_to_first_token_seconds_count{namespace="llm"}[5m])
```

### Time per Output Token (TPOT)

```promql
# P50 TPOT
histogram_quantile(0.50,
  rate(kserve_vllm:time_per_output_token_seconds_bucket{namespace="llm"}[5m])
)

# P95 TPOT
histogram_quantile(0.95,
  rate(kserve_vllm:time_per_output_token_seconds_bucket{namespace="llm"}[5m])
)

# P99 TPOT
histogram_quantile(0.99,
  rate(kserve_vllm:time_per_output_token_seconds_bucket{namespace="llm"}[5m])
)

# Average TPOT
rate(kserve_vllm:time_per_output_token_seconds_sum{namespace="llm"}[5m]) /
rate(kserve_vllm:time_per_output_token_seconds_count{namespace="llm"}[5m])
```

### End-to-End Request Latency

```promql
# P50 E2E latency
histogram_quantile(0.50,
  rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m])
)

# P95 E2E latency
histogram_quantile(0.95,
  rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m])
)

# P99 E2E latency
histogram_quantile(0.99,
  rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m])
)

# Average E2E latency
rate(kserve_vllm:e2e_request_latency_seconds_sum{namespace="llm"}[5m]) /
rate(kserve_vllm:e2e_request_latency_seconds_count{namespace="llm"}[5m])
```

---

## Throughput Metrics

### Token Generation Throughput

```promql
# Average output token generation rate (tokens/second)
kserve_vllm:avg_generation_throughput_toks_per_s{namespace="llm"}

# Average input token processing rate (tokens/second)
kserve_vllm:avg_prompt_throughput_toks_per_s{namespace="llm"}

# Total token throughput (input + output)
kserve_vllm:avg_prompt_throughput_toks_per_s{namespace="llm"} +
kserve_vllm:avg_generation_throughput_toks_per_s{namespace="llm"}
```

### Total Tokens Processed

```promql
# Total input tokens in last hour
increase(kserve_vllm:prompt_tokens_total{namespace="llm"}[1h])

# Total output tokens in last hour
increase(kserve_vllm:generation_tokens_total{namespace="llm"}[1h])

# Total tokens (input + output) in last hour
increase(kserve_vllm:prompt_tokens_total{namespace="llm"}[1h]) +
increase(kserve_vllm:generation_tokens_total{namespace="llm"}[1h])

# Total tokens in last 24 hours
increase(kserve_vllm:prompt_tokens_total{namespace="llm"}[24h]) +
increase(kserve_vllm:generation_tokens_total{namespace="llm"}[24h])
```

### Token Rate (Tokens per Request)

```promql
# Average input tokens per request
rate(kserve_vllm:prompt_tokens_total{namespace="llm"}[5m]) /
rate(kserve_vllm:request_success_total{namespace="llm"}[5m])

# Average output tokens per request
rate(kserve_vllm:generation_tokens_total{namespace="llm"}[5m]) /
rate(kserve_vllm:request_success_total{namespace="llm"}[5m])

# Average total tokens per request
(
  rate(kserve_vllm:prompt_tokens_total{namespace="llm"}[5m]) +
  rate(kserve_vllm:generation_tokens_total{namespace="llm"}[5m])
) /
rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
```

---

## Resource Metrics

### GPU Metrics

```promql
# GPU utilization (%) - correlate DCGM metrics with LLM pods by node
DCGM_FI_DEV_GPU_UTIL * on(node) group_right()
  kube_pod_info{namespace="llm", pod=~".*granite.*"}

# GPU memory usage (%) - CORRECT FORMULA
(
  DCGM_FI_DEV_FB_USED /
  (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
) * 100 * on(node) group_right()
  kube_pod_info{namespace="llm", pod=~".*granite.*"}

# GPU memory used (bytes)
DCGM_FI_DEV_FB_USED * on(node) group_right()
  kube_pod_info{namespace="llm", pod=~".*granite.*"}

# GPU temperature (celsius)
DCGM_FI_DEV_GPU_TEMP * on(node) group_right()
  kube_pod_info{namespace="llm", pod=~".*granite.*"}

# GPU power usage (watts)
DCGM_FI_DEV_POWER_USAGE * on(node) group_right()
  kube_pod_info{namespace="llm", pod=~".*granite.*"}

# Simpler alternative: Filter DCGM by GPU index if known
# DCGM_FI_DEV_GPU_UTIL{gpu="0", UUID="<gpu-uuid>"}
```

### GPU KV Cache Metrics

```promql
# GPU KV cache usage percentage
kserve_vllm:gpu_cache_usage_perc{namespace="llm"}

# CPU cache usage percentage (when swapping occurs)
kserve_vllm:cpu_cache_usage_perc{namespace="llm"}

# Number of preemptions (requests kicked out due to cache pressure)
rate(kserve_vllm:num_preemptions_total{namespace="llm"}[5m])

# Preemptions per minute
rate(kserve_vllm:num_preemptions_total{namespace="llm"}[5m]) * 60
```

### Pod CPU & Memory

```promql
# Pod CPU usage (cores)
rate(container_cpu_usage_seconds_total{
  namespace="llm",
  container="main",
  pod=~".*granite.*|.*llm.*"
}[5m])

# Pod CPU usage percentage (vs limit)
(
  rate(container_cpu_usage_seconds_total{
    namespace="llm",
    container="main",
    pod=~".*granite.*|.*llm.*"
  }[5m]) /
  kube_pod_container_resource_limits{
    namespace="llm",
    container="main",
    resource="cpu",
    pod=~".*granite.*|.*llm.*"
  }
) * 100

# Pod memory usage (bytes)
container_memory_working_set_bytes{
  namespace="llm",
  container="main",
  pod=~".*granite.*|.*llm.*"
}

# Pod memory usage percentage (vs limit)
(
  container_memory_working_set_bytes{
    namespace="llm",
    container="main",
    pod=~".*granite.*|.*llm.*"
  } /
  kube_pod_container_resource_limits{
    namespace="llm",
    container="main",
    resource="memory",
    pod=~".*granite.*|.*llm.*"
  }
) * 100
```

### Network & Disk I/O

```promql
# Network receive rate (bytes/sec)
rate(container_network_receive_bytes_total{
  namespace="llm",
  pod=~".*granite.*|.*llm.*"
}[5m])

# Network transmit rate (bytes/sec)
rate(container_network_transmit_bytes_total{
  namespace="llm",
  pod=~".*granite.*|.*llm.*"
}[5m])

# Disk read IOPS
rate(container_fs_reads_total{
  namespace="llm",
  pod=~".*granite.*|.*llm.*"
}[5m])

# Disk write IOPS
rate(container_fs_writes_total{
  namespace="llm",
  pod=~".*granite.*|.*llm.*"
}[5m])
```

---

## Business Metrics

### Requests by Model

```promql
# Request rate by model
sum by (model_name) (
  rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
)

# Total requests by model (last hour)
sum by (model_name) (
  increase(kserve_vllm:request_success_total{namespace="llm"}[1h])
)

# Request distribution by model (percentage)
(
  sum by (model_name) (
    rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
  ) /
  sum(
    rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
  )
) * 100
```

### Token Consumption by Model

```promql
# Total tokens by model (last hour)
sum by (model_name) (
  increase(kserve_vllm:prompt_tokens_total{namespace="llm"}[1h]) +
  increase(kserve_vllm:generation_tokens_total{namespace="llm"}[1h])
)

# Token consumption rate by model (tokens/sec)
sum by (model_name) (
  rate(kserve_vllm:prompt_tokens_total{namespace="llm"}[5m]) +
  rate(kserve_vllm:generation_tokens_total{namespace="llm"}[5m])
)

# Average tokens per request by model
(
  rate(kserve_vllm:prompt_tokens_total{namespace="llm"}[5m]) +
  rate(kserve_vllm:generation_tokens_total{namespace="llm"}[5m])
) /
sum by (model_name) (
  rate(kserve_vllm:request_success_total{namespace="llm"}[5m])
)
```

### Cost Estimation

```promql
# Estimated cost (last 24h) @ $0.02 per 1K tokens
(
  increase(kserve_vllm:prompt_tokens_total{namespace="llm"}[24h]) +
  increase(kserve_vllm:generation_tokens_total{namespace="llm"}[24h])
) * 0.00002

# Cost by model (last 24h)
sum by (model_name) (
  (
    increase(kserve_vllm:prompt_tokens_total{namespace="llm"}[24h]) +
    increase(kserve_vllm:generation_tokens_total{namespace="llm"}[24h])
  ) * 0.00002
)

# Cost breakdown: input vs output tokens (last 24h)
sum(increase(kserve_vllm:prompt_tokens_total{namespace="llm"}[24h])) * 0.00002
  +
sum(increase(kserve_vllm:generation_tokens_total{namespace="llm"}[24h])) * 0.00002
```

### Top Models

```promql
# Top 10 models by request count (last 24h)
topk(10,
  sum by (model_name) (
    increase(kserve_vllm:request_success_total{namespace="llm"}[24h])
  )
)

# Top models by token consumption (last 24h)
topk(10,
  sum by (model_name) (
    increase(kserve_vllm:prompt_tokens_total{namespace="llm"}[24h]) +
    increase(kserve_vllm:generation_tokens_total{namespace="llm"}[24h])
  )
)

# Top models by average latency (P95)
topk(10,
  histogram_quantile(0.95,
    sum by (model_name, le) (
      rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m])
    )
  )
)
```

---

## Troubleshooting Queries

### High Latency Investigation

```promql
# Models with P95 latency > 10 seconds
histogram_quantile(0.95,
  rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m])
) > 10

# Latency correlation with queue depth
(
  histogram_quantile(0.95,
    rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m])
  )
) and
(
  kserve_vllm:num_requests_waiting{namespace="llm"} > 10
)

# P95 TTFT (prompt processing latency)
# If high: prompt processing bottleneck
histogram_quantile(0.95,
  rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace="llm"}[5m])
)

# P95 TPOT (token generation latency)
# If high: token generation bottleneck
histogram_quantile(0.95,
  rate(kserve_vllm:time_per_output_token_seconds_bucket{namespace="llm"}[5m])
)
```

### Request Anomaly Detection

```promql
# Detect sudden drop in request rate (> 50% decrease)
(
  rate(kserve_vllm:request_success_total{namespace="llm"}[5m]) <
  rate(kserve_vllm:request_success_total{namespace="llm"}[5m] offset 10m) * 0.5
)

# Detect unusual spike in request rate (> 3x normal)
rate(kserve_vllm:request_success_total{namespace="llm"}[5m]) >
avg_over_time(rate(kserve_vllm:request_success_total{namespace="llm"}[5m])[15m:5m]) * 3

# Detect increasing queue depth trend
deriv(kserve_vllm:num_requests_waiting{namespace="llm"}[10m]) > 0.5
```

### Capacity Issues

```promql
# Queue depth growing over time
deriv(kserve_vllm:num_requests_waiting{namespace="llm"}[10m]) > 0

# High GPU cache usage with frequent preemptions
(kserve_vllm:gpu_cache_usage_perc{namespace="llm"} > 90) and
(rate(kserve_vllm:num_preemptions_total{namespace="llm"}[5m]) > 0.1)

# Pod near memory limit
(
  container_memory_working_set_bytes{
    namespace="llm",
    container="main"
  } /
  kube_pod_container_resource_limits{
    namespace="llm",
    container="main",
    resource="memory"
  }
) > 0.90
```

### Performance Degradation

```promql
# Token throughput drop (current vs 1h ago) - detect > 20% decrease
kserve_vllm:avg_generation_throughput_toks_per_s{namespace="llm"} <
(kserve_vllm:avg_generation_throughput_toks_per_s{namespace="llm"} offset 1h) * 0.8

# Request rate spike (3x normal over 15 min baseline)
rate(kserve_vllm:request_success_total{namespace="llm"}[5m]) >
avg_over_time(rate(kserve_vllm:request_success_total{namespace="llm"}[5m])[15m:5m]) * 3

# Latency degradation (P95 latency increased > 50%)
histogram_quantile(0.95,
  rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m])
) >
(
  histogram_quantile(0.95,
    rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[5m] offset 1h)
  ) * 1.5
)

# GPU cache pressure increasing
kserve_vllm:gpu_cache_usage_perc{namespace="llm"} > 90
  and
rate(kserve_vllm:num_preemptions_total{namespace="llm"}[5m]) > 0.1
```

### Health Checks

```promql
# Pod not ready
kube_pod_status_ready{
  namespace="llm",
  condition="true",
  pod=~".*granite.*|.*llm.*"
} == 0

# Recent pod restarts
changes(kube_pod_container_status_restarts_total{
  namespace="llm",
  container="main"
}[15m]) > 0

# OOMKilled events
kube_pod_container_status_terminated_reason{
  namespace="llm",
  reason="OOMKilled"
} > 0
```

---

## Tips for Writing PromQL Queries

1. **Use appropriate time ranges**:
   - Use `[5m]` for recent trends and rate calculations
   - Use `[1h]` for hourly aggregations
   - Use `[24h]` for daily totals
   - Use `[15m:5m]` for subquery baselines in anomaly detection

2. **Choose the right aggregation**:
   - `rate()` for per-second rates of counters
   - `increase()` for total count over time
   - `histogram_quantile()` for percentiles from histogram buckets
   - `deriv()` for detecting trends (increasing/decreasing)

3. **Filter efficiently**:
   - Always include `namespace="llm"` to scope queries to LLM workloads
   - Use `model_name` for grouping by model (not `tier` or `user`)
   - Use `finished_reason` to distinguish truncated (length) vs complete (stop) requests

4. **Group results meaningfully**:
   - `sum by (model_name)` for per-model metrics
   - `sum by (finished_reason)` for success vs truncation analysis
   - `sum by (pod)` for per-pod metrics
   - Include `le` when grouping histogram buckets

5. **Set sensible thresholds**:
   - P95 E2E latency > 10s: warning
   - P95 TTFT > 5s: warning
   - GPU cache > 95%: warning
   - Queue depth > 50: warning
   - Memory usage > 90%: critical

6. **GPU Metrics Correlation**:
   - DCGM metrics are in `nvidia-gpu-operator` namespace
   - Correlate with LLM pods using: `* on(node) group_right() kube_pod_info{namespace="llm"}`
   - GPU memory %: `USED / (USED + FREE)` not `USED / FREE`

7. **Avoid Non-Existent Metrics**:
   - Do NOT use `request_failure_total` (doesn't exist)
   - Do NOT use `istio_requests_total` (no Istio)
   - Do NOT use `tier` or `user` labels (not available)

## Testing Queries

All queries can be tested using:

1. **Grafana dashboards** - Queries are pre-configured in the three dashboards
2. **validate-metrics.sh** - Automated validation script that tests key metrics
3. **Direct Thanos Querier access**:
   ```bash
   TOKEN=$(oc whoami -t)
   curl -k -H "Authorization: Bearer $TOKEN" \
     'https://thanos-querier-openshift-monitoring.apps.<cluster-domain>/api/v1/query?query=<your-query>'
   ```
