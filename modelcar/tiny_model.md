# Deploying a Tiny Model with LLMInferenceService

This guide demonstrates how to create a ModelCar (OCI container image with model weights) and deploy it using LLMInferenceService on OpenShift with MaaS integration.

## Prerequisites

- OpenShift cluster with GPU nodes
- `oc` CLI installed and authenticated
- `podman` installed locally
- Python 3.8+ installed
- Quay.io account with push access

---

## Part 1: Download Model from HuggingFace

### Step 1: Set Up Environment

```bash
# Create working directory
mkdir -p ~/tiny-model
cd ~/tiny-model

# Verify tools
python3 --version  # Need 3.8+
podman --version   # Need 4.0+
oc whoami          # Verify OpenShift access
```

### Step 2: Install HuggingFace CLI

```bash
# Create Python virtual environment
python3 -m venv venv
source venv/bin/activate

# Install HuggingFace Hub CLI
pip install --upgrade pip
pip install --upgrade "huggingface_hub[cli]"

# Verify installation
hf version
```

**Optional: HuggingFace Authentication** (only for gated/private models)

```bash
# Only needed for gated/private models
hf auth login
# Enter your token from: https://huggingface.co/settings/tokens
```

### Step 3: Download Model

```bash
# Create download directory
mkdir -p model-download

# Download model (example: Qwen 2.5 3B Instruct)
echo "Starting model download..."

hf download Qwen/Qwen2.5-3B-Instruct --local-dir ./model-download/qwen-3b
```

**What's being downloaded:**
- `model.safetensors` - Model weights
- `config.json` - Model configuration
- `tokenizer.json` - Tokenizer data
- `tokenizer_config.json` - Tokenizer configuration
- `generation_config.json` - Generation settings
- Other metadata files

### Step 4: Verify Downloaded Model

```bash
# Check download completed successfully
ls -lh model-download/qwen-3b/

# Verify model files integrity
du -sh model-download/qwen-3b/

# Count safetensors files
ls model-download/qwen-3b/*.safetensors | wc -l
```

---

## Part 2: Package Model as ModelCar


### Step 5: Create ModelCar Dockerfile

```bash
# Create Dockerfile
cat > Dockerfile <<'EOF'
# Use Red Hat Universal Base Image (UBI) 9 Minimal
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Set user to root temporarily for directory creation
USER root

# Create /models directory (KServe standard location)
RUN mkdir -p /models && chmod 755 /models

# Copy model files to /models
COPY --chown=1001:0 model-download/qwen-3b/ /models/

# Switch to non-root user (OpenShift requirement)
USER 1001

# ===== Metadata Labels =====

# Component information
LABEL com.redhat.component="qwen-2.5-3b-instruct"
LABEL name="qwen-2.5-3b-instruct"
LABEL version="1.0"
LABEL summary="Qwen 2.5 3B Instruct model for inference"
LABEL description="Qwen 2.5 3B Instruct model optimized for NVIDIA A10G GPUs"

# Model-specific metadata
LABEL model.name="qwen-2.5-3b-instruct"
LABEL model.version="2.5"
LABEL model.family="qwen"
LABEL model.format="safetensors"
LABEL model.dtype="bfloat16"
LABEL model.parameters="3B"
LABEL model.license="Apache-2.0"

# Hardware recommendations
LABEL hardware.gpu.memory.min="8Gi"
LABEL hardware.gpu.type="nvidia-a10g,nvidia-t4,nvidia-l4"

# Security
LABEL security.unprivileged="true"
LABEL security.rootless="true"
EOF

echo "Dockerfile created successfully"
```

### Step 6: Build ModelCar Image

```bash
# Build the container image
echo "Building ModelCar image..."
podman build --platform linux/amd64 -t qwen-2-5-3b-instruct:1.0 -f Dockerfile .
```

**Build time**: ~5-10 minutes (depends on model size)

### Step 7: Verify Built Image

```bash
# List images to confirm build
podman images | grep qwen

# Expected output:
# localhost/qwen-2-5-3b-instruct  1.0  <id>  2 minutes ago  6.2 GB

# Inspect image details
podman inspect qwen-2-5-3b-instruct:1.0 | jq '.[0] | {
  Id: .Id,
  Size: .Size,
  Created: .Created
}'
```

### Step 8: Tag and Push to Quay

```bash
# Replace with your Quay username/organization
export QUAY_USER="your-quay-username"

# Tag the local image for Quay
podman tag localhost/qwen-2-5-3b-instruct:1.0 quay.io/${QUAY_USER}/qwen-2-5-3b-instruct:gori-1.0

# Verify tags
podman images | grep qwen

# Login to Quay (if not already logged in)
podman login quay.io

# Push both tags to Quay
podman push quay.io/${QUAY_USER}/qwen-2-5-3b-instruct:gori-1.0
```

---

## Part 3: Deploy Model with LLMInferenceService

### Step 9: Create Image Pull Secret

```bash
# Create secret for pulling from Quay
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username="YOUR_QUAY_USERNAME" \
  --docker-password="YOUR_QUAY_PASSWORD_OR_ROBOT_TOKEN" \
  -n llm \
  --dry-run=client -o yaml | oc apply -f -

# Link secret to default service account
oc secrets link default quay-pull-secret --for=pull -n llm
```

### Step 10: Create LLMInferenceService CR

```bash
# Replace with your Quay username
export QUAY_USER="your-quay-username"

cat > qwen-3b-llm.yaml <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen-2-5-3b-instruct
  namespace: llm
  annotations:
    alpha.maas.opendatahub.io/tiers: '[]'
spec:
  model:
    # Model name for API requests
    name: qwen-2.5-3b-instruct

    # OCI URI pointing to ModelCar in Quay
    uri: oci://quay.io/${QUAY_USER}/qwen-2-5-3b-instruct:gori-1.0

  # Single replica to start
  replicas: 1

  # Router configuration - integrate with MaaS Gateway
  router:
    route: {}
    gateway:
      refs:
        - name: maas-default-gateway
          namespace: openshift-ingress

  # vLLM container template
  template:
    # Schedule on GPU nodes
    nodeSelector:
      nvidia.com/gpu.present: "true"

    # Tolerate GPU taints
    tolerations:
      - effect: NoSchedule
        key: nvidia.com/gpu
        operator: Exists

    containers:
      - name: main
        # Red Hat ModelCar-compatible vLLM Runtime
        image: "registry.redhat.io/rhoai/odh-vllm-cuda-rhel9:v2.25.0-1759340926"
        imagePullPolicy: IfNotPresent

        # vLLM server command
        command:
          - python
          - -m
          - vllm.entrypoints.openai.api_server
        args:
          - --port=8000
          - --model=/mnt/models
          - --served-model-name=qwen-2.5-3b-instruct
          - --tensor-parallel-size=1
          - --gpu-memory-utilization=0.75
          - --dtype=auto
          - --max-model-len=8192
          - --max-num-seqs=256
          - --enable-chunked-prefill
          - --enable-prefix-caching
          - --disable-log-requests
          - --trust-remote-code
          - --ssl-certfile=/var/run/kserve/tls/tls.crt
          - --ssl-keyfile=/var/run/kserve/tls/tls.key

        env:
          # HuggingFace cache location
          - name: HF_HOME
            value: /tmp/hf_home

          # Disable telemetry
          - name: VLLM_NO_USAGE_STATS
            value: "1"

          # Offline mode (model in container)
          - name: HF_HUB_OFFLINE
            value: "1"

          # GPU configuration
          - name: CUDA_VISIBLE_DEVICES
            value: "0"

          - name: NVIDIA_VISIBLE_DEVICES
            value: "all"

          - name: NVIDIA_DRIVER_CAPABILITIES
            value: "compute,utility"

        # Resource allocation
        resources:
          requests:
            cpu: "1"
            memory: 12Gi
            nvidia.com/gpu: "1"
          limits:
            cpu: "2"
            memory: 16Gi
            nvidia.com/gpu: "1"

        # Health checks (HTTPS on port 8000)
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTPS
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 30
          failureThreshold: 5

        readinessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTPS
          initialDelaySeconds: 120
          periodSeconds: 10
          timeoutSeconds: 10
          failureThreshold: 30
EOF

echo "LLMInferenceService manifest created: qwen-3b-llm.yaml"
```

### Step 11: Deploy the Model

```bash
# Apply the CR
oc apply -f qwen-3b-llm.yaml

# Watch deployment progress
oc get llminferenceservice qwen-2-5-3b-instruct -n llm -w
```

**Press Ctrl+C when pod is running**

### Step 12: Verify Model Deployment

```bash
# Check LLMInferenceService status
oc get llminferenceservice qwen-2-5-3b-instruct -n llm

# Check pod status
oc get pods -n llm -l app.kubernetes.io/name=qwen-2-5-3b-instruct

# Check HTTPRoute created for MaaS Gateway
oc get httproute -n llm | grep qwen

# Check model logs (should see successful startup)
oc logs -f -l app.kubernetes.io/name=qwen-2-5-3b-instruct -n llm

```

### Step 13: Test the Model

#### Get Access Token

```bash
# Get Keycloak URL
export KEYCLOAK_URL=https://$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}')

# Get client secret
export CLIENT_SECRET=$(oc get secret keycloak-client-secret-maas-client -n rhsso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)

# Get access token
export ACCESS_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/auth/realms/maas/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=maas-client" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=testuser" \
  -d "password=password123" \
  -d "grant_type=password" | jq -r '.access_token')
```


#### Set Model URL

```bash
# Get MaaS Gateway URL
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MODEL_URL="https://maas.${CLUSTER_DOMAIN}/llm/qwen-2-5-3b-instruct"

echo "Model URL: ${MODEL_URL}"
```

#### Test : Chat Completions

```bash
# Test chat completions endpoint
curl -sk "${MODEL_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-2.5-3b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "You are a helpful assistant."
      },
      {
        "role": "user",
        "content": "What is the capital of France?"
      }
    ],
    "max_tokens": 100,
    "temperature": 0.7
  }' | jq .
```
---


