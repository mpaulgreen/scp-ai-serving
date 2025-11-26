# MaaS Platform Deployment Manifests

This directory contains the complete Kubernetes manifests for deploying the Model-as-a-Service (MaaS) platform on OpenShift with Red Hat OpenShift AI 3 (RHOAI).

**📖 New to MaaS?** Start with the [Installation Guide](./bom_3.0.0.md) to install all required operators first.

## Overview

The MaaS platform provides:
- **Token-based authentication** via ServiceAccount tokens
- **Tier-based access control** (free, premium, enterprise)
- **Request rate limiting** (per-tier and per-token)
- **Token rate limiting** (usage-based billing)
- **Gateway API integration** for model inference routing

---

## Installation Guide

**IMPORTANT:** Before deploying the MaaS platform, you must install all required operators and platform components.

📖 **Complete installation guide:** [bom_3.0.0.md](./bom_3.0.0.md)

Once all operators are installed and verified, proceed with the MaaS platform deployment below.

**If you deployed the test model in Phase 4 of the installation guide**, remove it before deploying the MaaS platform:

```bash
# Remove test model and route (if deployed in Phase 4)
oc delete route facebook-opt-125m-simulated -n llm --ignore-not-found=true
oc delete llminferenceservice facebook-opt-125m-simulated -n llm --ignore-not-found=true

# Optionally delete the llm namespace (if no other models are deployed)
# oc delete namespace llm
```

---

## Manifest Files

### 1. maas-platform.yaml
**Purpose:** Complete MaaS platform deployment including networking infrastructure

**Components:**

**Networking Infrastructure:**
- `kuadrant-system` namespace
- `Kuadrant` CR (creates Authorino and Limitador instances)
- `openshift-ai-inference` Gateway (required by RHOAI LLMInferenceService presets)

**MaaS Platform:**
- `maas-api` namespace
- ServiceAccount, ClusterRole, ClusterRoleBinding for MaaS API
- Tier-to-group mapping ConfigMap
- MaaS API Service and Deployment
- `maas-default-gateway` Gateway
- HTTPRoute for MaaS API endpoints
- AuthPolicy for authentication (token-based, not OAuth2)
- RateLimitPolicy 
- TokenRateLimitPolicy 
---


## Complete Deployment Workflow

**Step 0: Install all prerequisites** (if not already done)

See [bom_3.0.0.md](./bom_3.0.0.md) for complete operator installation instructions.

**Step 1-15: Deploy MaaS platform and model**

```bash
# 1. Set cluster domain
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# 2. Deploy MaaS platform (includes networking infrastructure)
cat maas-platform.yaml | envsubst | oc apply -f -

# 3. Check Kuadrant CR
oc get kuadrant -n kuadrant-system

# 4. Verify Authorino and Limitador are running
oc get pods -n kuadrant-system

# 5. Check MaaS API deployment
oc get deployment maas-api -n maas-api
oc get pods -n maas-api

# 6. Check Gateway
oc get gateway maas-default-gateway -n openshift-ingress

# 7. Check HTTPRoute
oc get httproute maas-api-route -n maas-api

# 8. Check Policies
oc get authpolicy -n openshift-ingress
oc get authpolicy -n maas-api
oc get ratelimitpolicy -n openshift-ingress
oc get tokenratelimitpolicy -n openshift-ingress

# 9. Wait for Kuadrant to be ready
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=300s

# 10. Wait for MaaS API to be ready
oc wait --for=condition=Available deployment/maas-api -n maas-api --timeout=300s

# 11. Deploy example model
oc apply -f model_maas.yaml

# 12. Wait for model to be ready
oc wait --for=condition=Ready llminferenceservice/facebook-opt-125m-simulated -n llm --timeout=600s

# 13. Check auto-generated HTTPRoute (created in llm namespace, references gateway in openshift-ingress)
oc get httproute -n llm

# 14. Verify HTTPRoute configuration
oc get httproute -n llm -o yaml | grep -A 5 "parentRefs:"
# Should show: name: maas-default-gateway, namespace: openshift-ingress

# 15. Check LLMInferenceService status and URL
oc get llminferenceservice -n llm
```

## Testing the Deployment

### 1. Verify Gateway is Running

```bash
# Verify CLUSTER_DOMAIN is set
echo $CLUSTER_DOMAIN

# Check MaaS gateway status
oc get gateway maas-default-gateway -n openshift-ingress

# Check MaaS API HTTPRoute
oc get httproute maas-api-route -n maas-api

# Test gateway connectivity (should return 401 - auth required)
curl -sk -w "\nHTTP: %{http_code}\n" "https://maas.${CLUSTER_DOMAIN}/maas-api/health"

# Expected output:
# HTTP: 401
# (All MaaS API endpoints require authentication, including health)
```

### 2. Get MaaS Token

```bash
# Authenticate to OpenShift
oc login ...

# Get OpenShift token
export OC_TOKEN=$(oc whoami -t)

# Exchange for MaaS token
export MAAS_TOKEN=$(curl -sk "https://maas.${CLUSTER_DOMAIN}/maas-api/v1/tokens" \
  -H "Authorization: Bearer $OC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"expiration": "10m"}' | jq -r .token)

echo "MaaS Token: $MAAS_TOKEN"

# Test MaaS API health WITH authentication
curl -sk "https://maas.${CLUSTER_DOMAIN}/maas-api/health" \
  -H "Authorization: Bearer $OC_TOKEN"

# Expected output:
# {"status":"healthy"}
```

### 3. Test Model Inference

```bash
# Make inference request
curl -sk "https://maas.${CLUSTER_DOMAIN}/llm/facebook-opt-125m-simulated/v1/chat/completions" \
  -H "Authorization: Bearer $MAAS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "facebook/opt-125m",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ]
  }' | jq .
```
---