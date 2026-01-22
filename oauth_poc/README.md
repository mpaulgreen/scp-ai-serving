# OAuth Authentication Quick Start Guide

Quick reference for deploying MaaS platform with Keycloak OAuth authentication.

## Prerequisites

- Complete [maas/bom_3.0.0.md](../maas/bom_3.0.0.md) - RHOAI 3.0.0 installation
- OpenShift cluster with valid TLS certificates from a trusted CA (not self-signed)

## Quick Setup (5 Steps)

### 1. Install Keycloak Operator

```bash
oc apply -f keycloak-operator.yaml
sleep 15
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/rhsso-operator -n rhsso --timeout=300s
```

### 2. Deploy Keycloak Instance

```bash
oc apply -f keycloak-instance.yaml

# Wait for Keycloak to be ready (2-3 minutes)
# Verify status
oc get keycloak keycloak -n rhsso -o jsonpath='{.status.ready}'
echo ""

# Get admin password
KEYCLOAK_ADMIN_PASSWORD=$(oc get secret credential-keycloak -n rhsso -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
echo "Keycloak Admin Password: ${KEYCLOAK_ADMIN_PASSWORD}"

# Get Keycloak URL
KEYCLOAK_URL=https://$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}')
echo "Keycloak Admin Console: ${KEYCLOAK_URL}/auth/admin"
```

### 3. Create Realm and Client

```bash
oc apply -f keycloak-realm.yaml
sleep 20
oc get keycloakrealm maas-realm -n rhsso

oc apply -f keycloak-client.yaml
sleep 20
oc get keycloakclient maas-client -n rhsso

# Get client secret
CLIENT_SECRET=$(oc get secret keycloak-client-secret-maas-client -n rhsso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)
echo "Client Secret: ${CLIENT_SECRET}"
```

### 4. Create Test User (via Keycloak Admin Console)

1. Open: `${KEYCLOAK_URL}/auth/admin` (or use the URL printed in step 2)
2. Login: `admin` / `${KEYCLOAK_ADMIN_PASSWORD}`
3. Select `maas` realm from the dropdown (top-left corner)
4. **Create Groups:**
   - Groups → Create: `tier-free-users`
   - Groups → Create: `tier-premium-users`
   - Groups → Create: `tier-enterprise-users`
5. **Create User:**
   - Users → Add User
   - Username: `testuser`
   - Credentials → Set Password: `password123`
   - Groups → Join: `tier-premium-users`

### 5. Deploy MaaS Platform with OAuth

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export KEYCLOAK_ISSUER="https://$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}')/auth/realms/maas"

cat maas-platform-oauth.yaml | envsubst | oc apply -f -

# Deploy model
oc apply -f ../maas/model_maas.yaml
oc wait --for=condition=Ready llminferenceservice/facebook-opt-125m-simulated -n llm --timeout=600s
```

## Test OAuth Authentication

### Get OAuth Token

```bash
export KEYCLOAK_URL=https://$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}')
export CLIENT_SECRET=$(oc get secret keycloak-client-secret-maas-client -n rhsso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)

# Get access token
ACCESS_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/auth/realms/maas/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=maas-client" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=testuser" \
  -d "password=password123" \
  -d "grant_type=password" | jq -r '.access_token')

echo "Access Token obtained: ${ACCESS_TOKEN:0:50}..."
```

### Test Model Inference

```bash
# Set the Gateway-based model URL (path-based routing)
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MODEL_URL="https://maas.${CLUSTER_DOMAIN}/llm/facebook-opt-125m-simulated"

# Test completion (recommended)
curl -sk "${MODEL_URL}/v1/completions" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "facebook/opt-125m",
    "prompt": "Hello world",
    "max_tokens": 10
  }' | jq .

# Expected: HTTP 200 with JSON response containing "choices" array with generated text

# Test chat completion
curl -sk "${MODEL_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "facebook/opt-125m",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ],
    "max_tokens": 50
  }' | jq .
```

## Test Rate Limiting

The MaaS platform enforces tier-based rate limiting. Each tier has different limits:

**Default Rate Limits (per user, per 2 minutes):**
- **Free tier**: 5 requests per 2 minutes
- **Premium tier**: 20 requests per 2 minutes
- **Enterprise tier**: 50 requests per 2 minutes

### Verify Current User Tier

```bash
# Decode JWT token to see user groups
echo $ACCESS_TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .

# Look for "groups" claim:
# "groups": ["tier-premium-users"]  ← Premium tier (20 requests per 2 min)
```

### Test Rate Limit Enforcement

**Test Premium Tier Limits (20 requests per 2 minutes):**

Create a test script:

```bash
cat > test-rate-limit.sh << 'EOF'
#!/bin/bash

# Test rate limiting for Premium tier (20 requests per 2 minutes)
echo "Testing rate limits for Premium tier (20 requests per 2 minutes)..."
echo "Making 25 requests rapidly..."
echo ""

for i in {1..25}
do
  echo -n "Request $i: "

  HTTP_CODE=$(curl -sk -w "%{http_code}" -o /dev/null \
    "${MODEL_URL}/v1/completions" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"facebook/opt-125m","prompt":"test","max_tokens":5}')

  if [ "$HTTP_CODE" = "200" ]; then
    echo "Success"
  elif [ "$HTTP_CODE" = "429" ]; then
    echo "Rate Limited - Limit reached!"
  else
    echo "Error (HTTP $HTTP_CODE)"
  fi

  sleep 0.5
done

echo ""
echo "Expected: First 20 requests succeed, requests 21-25 return HTTP 429"
EOF

chmod +x test-rate-limit.sh
```

Run the test:

```bash
export MODEL_URL="https://maas.${CLUSTER_DOMAIN}/llm/facebook-opt-125m-simulated"

./test-rate-limit.sh
```

