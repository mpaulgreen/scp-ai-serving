# Deploying Granite 3.1 8B Instruct with LLMInferenceService

This demonstrates how to create a ModelCar (OCI container image with model weights) for the IBM Granite 3.1 8B Instruct model and deploy it using LLMInferenceService on OpenShift with MaaS integration.

## Prerequisites

### OpenShift Cluster Requirements
- OpenShift cluster with GPU nodes (NVIDIA A10G or better)
- At least 1 GPU node with 64GB+ RAM
- NVIDIA GPU Operator installed
- Cluster-admin or namespace admin permissions

### Local Requirements
- `oc` CLI installed and authenticated
- Quay.io account with push access

### Verify Prerequisites

```bash
# Verify you can access the cluster
oc whoami

# Verify GPU nodes exist
oc get nodes -l nvidia.com/gpu.present=true
```

---

## Part 1: Prepare Build Environment on OpenShift

### Step 1: Create Build Namespace

```bash
# Create namespace for model building
oc create namespace granite-build
```

### Step 2: Create Quay Push Secret

```bash
# Create secret for pushing to Quay
# Replace with your actual Quay credentials
oc create secret docker-registry quay-push-secret \
  --docker-server=quay.io \
  --docker-username="YOUR_QUAY_USERNAME" \
  --docker-password="YOUR_QUAY_PASSWORD_OR_ROBOT_TOKEN" \
  -n granite-build \
  --dry-run=client -o yaml | oc apply -f -
```

**Note**: Replace with your actual Quay credentials:
- `YOUR_QUAY_USERNAME`: Your Quay.io username
- `YOUR_QUAY_PASSWORD_OR_ROBOT_TOKEN`: Your password or robot account token

### Step 3: Create PersistentVolumeClaim for Build Workspace

```bash
# Create PVC for build workspace (150Gi for model + buildah layers + buffer)
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: granite-build-workspace
  namespace: granite-build
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 150Gi
  storageClassName: gp3-csi  # Use your cluster's storage class
EOF

# Verify PVC is bound
oc get pvc granite-build-workspace -n granite-build
```

### Step 4: Create ServiceAccount with Privileged Access

```bash
# Create service account for building container images
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: granite-builder
  namespace: granite-build
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: granite-builder-privileged
  namespace: granite-build
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
- kind: ServiceAccount
  name: granite-builder
  namespace: granite-build
EOF

# Link secret to service account
oc secrets link granite-builder quay-push-secret -n granite-build
```

---

## Part 2: Create GPU Build Pod

### Step 5: Create Build Pod YAML

This pod uses a PVC for workspace storage to avoid node ephemeral storage limits and eviction issues.

```bash
cat > granite-build-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: granite-model-builder
  namespace: granite-build
  labels:
    app: granite-builder
spec:
  serviceAccountName: granite-builder

  # Ensure pod runs on GPU node
  nodeSelector:
    nvidia.com/gpu.present: "true"

  # Tolerate GPU taints
  tolerations:
    - effect: NoSchedule
      key: nvidia.com/gpu
      operator: Exists

  restartPolicy: Never

  containers:
    - name: builder
      # Use Red Hat UBI 9 with Python and development tools
      image: registry.access.redhat.com/ubi9/python-311:latest

      # Run as privileged to allow buildah to build containers
      securityContext:
        privileged: true
        runAsUser: 0

      # Keep pod running for manual work
      command: ["sleep"]
      args: ["infinity"]

      env:
        # GPU configuration
        - name: NVIDIA_VISIBLE_DEVICES
          value: "all"
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: "compute,utility"
        - name: CUDA_VISIBLE_DEVICES
          value: "0"

        # Python configuration
        - name: PYTHONUNBUFFERED
          value: "1"

        # HuggingFace token (if needed for gated models)
        # - name: HF_TOKEN
        #   valueFrom:
        #     secretKeyRef:
        #       name: hf-token-secret
        #       key: token

      resources:
        requests:
          cpu: "8"
          memory: 32Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "16"
          memory: 64Gi
          nvidia.com/gpu: "1"

      volumeMounts:
        # Mount Quay credentials for buildah
        - name: quay-auth
          mountPath: /root/.docker
          readOnly: true

        # Mount PVC for model files and buildah workspace
        - name: workspace
          mountPath: /workspace

        # Mount PVC for buildah container storage (prevents ephemeral storage usage)
        - name: workspace
          mountPath: /var/lib/containers
          subPath: buildah-storage

  volumes:
    # Quay authentication
    - name: quay-auth
      secret:
        secretName: quay-push-secret
        items:
          - key: .dockerconfigjson
            path: config.json

    # PVC for model files and buildah workspace (150Gi dedicated storage)
    - name: workspace
      persistentVolumeClaim:
        claimName: granite-build-workspace
EOF

```

### Step 6: Deploy Build Pod

```bash
# Apply the pod
oc apply -f granite-build-pod.yaml

# Wait for pod to be running (may take 2-3 minutes)
oc wait --for=condition=Ready pod/granite-model-builder -n granite-build --timeout=300s

# Verify pod is running and has GPU access
oc get pod granite-model-builder -n granite-build

# Check GPU allocation
oc describe pod granite-model-builder -n granite-build | grep -A 5 "nvidia.com/gpu"
```

---

## Part 3: Install Tools and Download Model

### Step 7: Access the Build Pod

```bash
# Exec into the pod
oc exec -it granite-model-builder -n granite-build -- bash

# All following commands run INSIDE the pod
# You'll see a prompt like: bash-5.1#
```

### Step 8: Install System Dependencies

```bash
# Update package manager
dnf update -y

# Install buildah for container image building
dnf install -y buildah fuse-overlayfs slirp4netns

# Verify buildah installation
buildah --version
```

### Step 9: Install Python Dependencies

```bash
# Upgrade pip
pip install --upgrade pip

# Install HuggingFace CLI
pip install --upgrade "huggingface_hub[cli]"

# Verify HuggingFace CLI
hf version
```

### Step 10: Configure Buildah to Use PVC Storage


```bash
# Verify buildah will use PVC storage (mounted at /var/lib/containers)
ls -la /var/lib/containers

# Configure buildah storage
cat > /etc/containers/storage.conf <<'CONF'
[storage]
driver = "overlay"
runroot = "/var/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
CONF

# Verify buildah configuration points to PVC
buildah info

# Expected output should show:
#   graphRoot: /var/lib/containers/storage (this is on PVC)
```


### Step 11: Download Granite Model

```bash
# Create working directory
cd /workspace
mkdir -p granite-build
cd granite-build

# Verify disk space (need ~50GB)
df -h /workspace

# Set model name
export MODEL_NAME="ibm-granite/granite-3.1-8b-instruct"
export MODEL_DIR="/workspace/granite-build/model-base"

# Download model from HuggingFace
# This downloads the base BF16 model (~16GB)
echo "Downloading Granite 3.1 8B Instruct from HuggingFace..."
echo "This will take 15-30 minutes depending on network speed..."

hf download ${MODEL_NAME} --local-dir ${MODEL_DIR}

# Verify download
ls -lh ${MODEL_DIR}

# Expected files:
# - config.json
# - tokenizer.json
# - tokenizer_config.json
# - model-*.safetensors (multiple files totaling ~16GB)
# - generation_config.json

# Check model size
du -sh ${MODEL_DIR}
# Expected: ~16GB
```

**Download time**: ~15-30 minutes depending on network speed

---

## Part 4: Build and Push ModelCar Image

### Step 12: Create Dockerfile

```bash
cd /workspace/granite-build

# Create Dockerfile for ModelCar
cat > Dockerfile <<'EOF'
# Use Red Hat Universal Base Image (UBI) 9 Minimal
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Set user to root temporarily for directory creation
USER root

# Create /models directory (KServe ModelCar standard location)
RUN mkdir -p /models && chmod 755 /models

# Copy model files to /models (BF16 format for vLLM runtime quantization)
# chown 1001:0 sets ownership for OpenShift unprivileged containers
COPY --chown=1001:0 model-base/ /models/

# Switch to non-root user (OpenShift Security Context Constraint requirement)
USER 1001

# ===== Metadata Labels =====

# Component information
LABEL com.redhat.component="granite-3.1-8b-instruct-fp8"
LABEL name="granite-3.1-8b-instruct-fp16"
LABEL version="1.0"
LABEL summary="IBM Granite 3.1 8B Instruct FP8 quantized model for inference"
LABEL description="Granite 3.1 8B Instruct model with FP8 quantization optimized for NVIDIA A10G GPUs"

# Model-specific metadata
LABEL model.name="granite-3.1-8b-instruct"
LABEL model.version="3.1"
LABEL model.family="granite"
LABEL model.format="safetensors"
LABEL model.dtype="bfloat16"
LABEL model.quantization="vllm-runtime-fp8"
LABEL model.quantization-note="BF16 weights, FP8 applied by vLLM at runtime"
LABEL model.parameters="8B"
LABEL model.context-length="4096"
LABEL model.license="Apache-2.0"
LABEL model.source="huggingface"
LABEL model.repository="ibm-granite/granite-3.1-8b-instruct"

# Hardware recommendations
LABEL hardware.gpu.memory.min="12Gi"
LABEL hardware.gpu.memory.recommended="16Gi"
LABEL hardware.gpu.type="nvidia-a10g,nvidia-a100,nvidia-l4"

# Security
LABEL security.unprivileged="true"
LABEL security.rootless="true"
EOF

echo "Dockerfile created successfully"
cat Dockerfile
```

### Step 13: Build ModelCar Image with Buildah

```bash
cd /workspace/granite-build

# Build the container image
echo "Building ModelCar image with buildah..."

buildah bud \
  --format=oci \
  --platform=linux/amd64 \
  -t granite-3.1-8b-instruct-fp8:gori-1.0 \
  -f Dockerfile \
  .

# Verify image built successfully
buildah images | grep granite

# Expected output:
# localhost/granite-3.1-8b-instruct-fp8  1.0  <image-id>  X minutes ago  16.5 GB
```

### Step 14: Tag Image for Quay

```bash
# Replace with your Quay username
export QUAY_USER="your-quay-username"

# Tag for quay.io
buildah tag \
  localhost/granite-3.1-8b-instruct-fp8:1.0 \
  quay.io/${QUAY_USER}/granite-3.1-8b-instruct-fp8:gori-1.0


# Verify tags
buildah images | grep granite
```

### Step 15: Push Image to Quay

```bash
# Verify buildah can see Quay credentials
cat /root/.docker/config.json
# Should show quay.io with auth token

# Push version 1.0
buildah push quay.io/${QUAY_USER}/granite-3.1-8b-instruct-fp8:gori-1.0
```

### Step 16: Cleanup Build Pod

```bash
# Exit the pod
exit

# From your local machine, delete the build pod
oc delete pod granite-model-builder -n granite-build

# PVC with model files remains intact for future builds
# Or delete entire namespace (removes pod, PVC, secrets, everything)
# oc delete namespace granite-build
```
---

## Part 5: Deploy Model with LLMInferenceService

### Step 17: Create Image Pull Secret

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

**Note**: Replace with your actual Quay credentials:
- `YOUR_QUAY_USERNAME`: Your Quay.io username or robot account name
- `YOUR_QUAY_PASSWORD_OR_ROBOT_TOKEN`: Your password or robot account token

### Step 18: Create LLMInferenceService CR

**vLLM Runtime Choice:**

This guide uses the **Red Hat ModelCar-compatible vLLM runtime** (`registry.redhat.io/rhoai/odh-vllm-cuda-rhel9:v2.25.0-1759340926`), which is:

```bash
# Replace with your Quay username
export QUAY_USER="your-quay-username"

cat > granite-8b-llm.yaml <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: granite-3-1-8b-instruct-fp8
  namespace: llm
  annotations:
    alpha.maas.opendatahub.io/tiers: '[]'
spec:
  model:
    # Model name for API requests
    name: granite-3.1-8b-instruct-fp8

    # OCI URI pointing to ModelCar in Quay
    uri: oci://quay.io/${QUAY_USER}/granite-3.1-8b-instruct-fp8:gori-1.0

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

    # Image pull secrets for private Quay registry
    imagePullSecrets:
      - name: quay-pull-secret

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
          - --served-model-name=granite-3.1-8b-instruct-fp8
          - --quantization=fp8
          - --tensor-parallel-size=1
          - --gpu-memory-utilization=0.85
          - --dtype=auto
          - --max-model-len=4096
          - --max-num-seqs=128
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

        # Resource allocation (larger model needs more resources)
        resources:
          requests:
            cpu: "8"
            memory: 32Gi
            nvidia.com/gpu: "1"
          limits:
            cpu: "16"
            memory: 64Gi
            nvidia.com/gpu: "1"

        # Health checks (HTTPS on port 8000)
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTPS
          initialDelaySeconds: 180
          periodSeconds: 30
          timeoutSeconds: 30
          failureThreshold: 5

        readinessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTPS
          initialDelaySeconds: 180
          periodSeconds: 10
          timeoutSeconds: 10
          failureThreshold: 30
EOF

echo "LLMInferenceService manifest created: granite-8b-llm.yaml"
```

### Step 19: Deploy the Model

```bash
# Apply the CR
oc apply -f granite-8b-llm.yaml

# Watch deployment progress
oc get llminferenceservice granite-3-1-8b-instruct-fp8 -n llm -w

```

**Press Ctrl+C when pod is running**

### Step 20: Verify Model Deployment

```bash
# Check LLMInferenceService status
oc get llminferenceservice granite-3-1-8b-instruct-fp8 -n llm

# Check pod status
oc get pods -n llm -l app.kubernetes.io/name=granite-3-1-8b-instruct-fp8

# Check HTTPRoute created for MaaS Gateway
oc get httproute -n llm | grep granite

# Check model logs (should see successful startup)
oc logs -f -l app.kubernetes.io/name=granite-3-1-8b-instruct-fp8 -n llm
```

### Step 21: Test the Model

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
export MODEL_URL="https://maas.${CLUSTER_DOMAIN}/llm/granite-3-1-8b-instruct-fp8"

echo "Model URL: ${MODEL_URL}"
```

#### Test: Chat Completions

```bash
# Test chat completions endpoint
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
        "content": "What is OpenShift and why is it important for enterprise deployments?"
      }
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }' | jq .
```

---