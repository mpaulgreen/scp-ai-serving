# MaaS Platform with IBM Security Verify SaaS Authentication

Deployment of Model-as-a-Service (MaaS) platform with IBM Security Verify SaaS for OAuth/OIDC authentication and tier-based rate limiting.

**📖 New to MaaS?** Start with the [Installation Guide](../maas/bom_3.0.0.md) to install all required operators first.

## Overview

The MaaS platform provides:
- **Token-based authentication** via ServiceAccount tokens
- **Tier-based access control** (free, premium, enterprise)
- **Request rate limiting** (per-tier and per-token)
- **Token rate limiting** (usage-based billing)
- **Gateway API integration** for model inference routing

## IBM Security Verify SaaS Configuration

### Current Configuration

The manifests require the following credentials to be set as environment variables:

- **Client ID**: Set via `IBM_VERIFY_CLIENT_ID` environment variable
- **Client Secret**: Set via `IBM_VERIFY_CLIENT_SECRET` environment variable
- **Tenant**: Set via `IBM_VERIFY_TENANT` environment variable

### User Groups Configuration

Configure user groups in IBM Security Verify SaaS for tier-based access:

1. **Navigate to**: Directory → Groups
2. **Create Groups**:
   - `tier-free-users` - Free tier (5 req/2min, 100 tokens/min)
   - `tier-premium-users` - Premium tier (20 req/2min, 50k tokens/min)
   - `tier-enterprise-users` - Enterprise tier (50 req/2min, 100k tokens/min)

3. **Assign Users**: Directory → Users → Edit → Groups → Join

## Deployment Instructions

### Step 1: Set Environment Variables

```bash
# Set IBM Verify SaaS credentials
export IBM_VERIFY_TENANT="your-tenant-name"  # e.g., test-maas
export IBM_VERIFY_CLIENT_ID="your-client-id"
export IBM_VERIFY_CLIENT_SECRET="your-client-secret"

# Set cluster domain
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# Set IBM Verify issuer URL
export IBM_VERIFY_ISSUER="https://${IBM_VERIFY_TENANT}.verify.ibm.com/oidc/endpoint/default"

# Set Quay credentials (for model deployment)
export QUAY_USER="your-quay-org"                    # Organization name (e.g., mpaulgreen)
export QUAY_ROBOT_USER="org+robotname"              # Robot account (e.g., mpaulgreen+mpaulrobo)
export QUAY_PASSWORD="robot-account-token"          # Robot account token

# Verify environment variables
echo "IBM Verify Tenant: ${IBM_VERIFY_TENANT}"
echo "IBM Verify Client ID: ${IBM_VERIFY_CLIENT_ID:0:20}..."
echo "Cluster Domain: ${CLUSTER_DOMAIN}"
echo "Issuer URL: ${IBM_VERIFY_ISSUER}"
```

### Step 2: Deploy MaaS Platform

```bash
# Deploy MaaS platform with IBM Verify SaaS authentication
cat maas-platform-verify.yaml | envsubst | oc apply -f -

# Wait for Kuadrant components to be ready
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=300s

# Wait for MaaS API to be ready
oc wait --for=condition=Available deployment/maas-api -n maas-api --timeout=300s
```

### Step 3: Verify Platform Deployment

```bash
# Check Kuadrant
oc get kuadrant -n kuadrant-system

# Check MaaS API
oc get deployment,service -n maas-api

# Check Gateway
oc get gateway maas-default-gateway -n openshift-ingress

# Check AuthPolicy
oc get authpolicy -n openshift-ingress
oc get authpolicy -n maas-api

# Check RateLimitPolicy
oc get ratelimitpolicy -n openshift-ingress
oc get tokenratelimitpolicy -n openshift-ingress
```

### Step 4: Deploy Granite Model

**Prerequisites**: Build and push ModelCar image following [../modelcar/large_model.md](../modelcar/large_model.md)

```bash
# Deploy Granite 3.1 8B Instruct model
cat granite-model.yaml | envsubst | oc apply -f -

# Wait for model to be ready (5-10 minutes)
oc wait --for=condition=Ready llminferenceservice/granite-3-1-8b-instruct-fp8 -n llm --timeout=600s

# Check model status
oc get llminferenceservice -n llm
oc get pods -n llm -l app.kubernetes.io/name=granite-3-1-8b-instruct-fp8

# Check HTTPRoute created for model
oc get httproute -n llm | grep granite
```

## Testing Authentication and Rate Limiting

### Step 1: Get JWT Access Token

```bash
# Set IBM Verify credentials (same as deployment)
export IBM_VERIFY_TENANT="test-maas"
export CLIENT_ID=""
export CLIENT_SECRET=""

# Get JWT access token using Resource Owner Password Credentials (ROPC) flow
export ACCESS_TOKEN=$(curl -sk -X POST \
  "https://${IBM_VERIFY_TENANT}.verify.ibm.com/oidc/endpoint/default/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=testuser" \
  -d "password=password123" \
  -d "grant_type=password" \
  -d "scope=openid profile email" | jq -r '.access_token')

echo "JWT Access Token obtained: ${ACCESS_TOKEN:0:100}..."
```


### Step 2: Verify JWT Token Claims

```bash
# Decode JWT payload to view claims
JWT_PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d'.' -f2)

# Add padding if needed
case $((${#JWT_PAYLOAD} % 4)) in
  2) JWT_PAYLOAD="${JWT_PAYLOAD}==" ;;
  3) JWT_PAYLOAD="${JWT_PAYLOAD}=" ;;
esac

# Decode and display claims
if [[ "$OSTYPE" == "darwin"* ]]; then
  echo "$JWT_PAYLOAD" | base64 -D | jq .
else
  echo "$JWT_PAYLOAD" | base64 -d | jq .
fi

# Expected claims:
# - "sub": user ID (e.g., "644006C3Z6")
# - "groups": "tier-premium-users"
# - "iss": "https://test-maas.verify.ibm.com/oidc/endpoint/default"
# - "aud": client ID
```

### Step 3: Test Model Inference

```bash
# Set model URL
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MODEL_URL="https://maas.${CLUSTER_DOMAIN}/llm/granite-3-1-8b-instruct-fp8"

echo "Model URL: ${MODEL_URL}"

# Test chat completions
curl -sk "${MODEL_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-3.1-8b-instruct-fp8",
    "messages": [
      {
        "role": "system",
        "content": "You are a helpful AI assistant."
      },
      {
        "role": "user",
        "content": "What is OpenShift and why is it important for enterprise AI deployments?"
      }
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }' | jq .

# Expected: HTTP 200 with JSON response containing "choices" array
```

### Step 4: Test Rate Limiting

Create a test script to verify tier-based rate limits:

```bash
cat > test-rate-limit.sh << 'EOF'
#!/bin/bash

# Test rate limiting based on user tier
# Premium tier: 20 requests per 2 minutes
# Free tier: 5 requests per 2 minutes
# Enterprise tier: 50 requests per 2 minutes

echo "Testing rate limits..."
echo "Making 25 requests rapidly..."
echo ""

SUCCESS=0
RATE_LIMITED=0

for i in {1..25}
do
  echo -n "Request $i: "

  HTTP_CODE=$(curl -sk -w "%{http_code}" -o /dev/null \
    "${MODEL_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "granite-3.1-8b-instruct-fp8",
      "messages": [{"role": "user", "content": "test"}],
      "max_tokens": 5
    }')

  if [ "$HTTP_CODE" = "200" ]; then
    echo "Success"
    ((SUCCESS++))
  elif [ "$HTTP_CODE" = "429" ]; then
    echo "Rate Limited"
    ((RATE_LIMITED++))
  else
    echo "Error (HTTP $HTTP_CODE)"
  fi

  sleep 0.5
done

echo ""
echo "Results:"
echo "  Successful requests: $SUCCESS"
echo "  Rate limited: $RATE_LIMITED"
echo ""
echo "Expected based on tier:"
echo "  Free tier: 5 success, 20 rate limited"
echo "  Premium tier: 20 success, 5 rate limited"
echo "  Enterprise tier: 25 success, 0 rate limited"
EOF

chmod +x test-rate-limit.sh

# Run the test
./test-rate-limit.sh
```