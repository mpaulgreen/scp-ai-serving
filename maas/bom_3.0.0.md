# OpenShift AI 3 Model Serving Deployment Guide
## KServe with GPU Support for LLM Inference

**Prerequisites:**
- OpenShift 4.19+ cluster with cluster-admin access

**Tested on**
- Openshift AI Self Managed on AWS

## Target Configuration:

**GPU Support:**
- Node Feature Discovery (NFD) Operator 4.19.0-202510211212
- NVIDIA GPU Operator 25.10.0

**Platform Operators:**
- Red Hat OpenShift AI (RHOAI) 3.0.0
- Red Hat OpenShift Service Mesh 3.x (auto-installed with RHOAI)
- cert-manager for Red Hat OpenShift 1.18.0
- Leader Worker Set Operator 1.0.0
- Red Hat Connectivity Link (RHCL) 1.2.0
  - Authorino Operator 1.2.4
  - Limitador Operator 1.2.0
  - DNS Operator 1.2.0

**Model Serving:**
- DataScienceCluster with KServe enabled
- Service Mesh 3 Istio Gateway

----
**MaaS Platform:**
- MaaS API with token-based authentication
- Kuadrant CR (Authorino and Limitador instances)
- Gateway API resources (Gateways, HTTPRoutes, Policies)

**Prerequisites:**
- OpenShift 4.19+ cluster with cluster-admin access
- `oc`, `kubectl`, `jq`, `kustomize` v5.7.0+ installed
- Sufficient cluster resources (CPU, memory, storage)

**Refer**
- [Red Hat OpenShift AI 3.0.0 - Installing and Uninstalling in a Disconnected Environment](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html-single/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/index)
- [Maas Billing](https://github.com/opendatahub-io/maas-billing/tree/main/deployment)

---

## Phase 1: GPU Prerequisites (Node Feature Discovery & NVIDIA GPU Operator)

**IMPORTANT:** GPU support must be configured BEFORE installing model serving components.

### 1.1 Install Node Feature Discovery (NFD) Operator
A NFD automatically detects hardware features on nodes and labels them accordingly.

```bash
# Create namespace
oc create namespace openshift-nfd --dry-run=client -o yaml | oc apply -f -

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator to be ready
sleep 15
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/nfd -n openshift-nfd --timeout=300s

# Verify CSV
oc get csv -n openshift-nfd
```


### 1.2 Create NodeFeatureDiscovery Instance

```bash
# Create NodeFeatureDiscovery instance
cat <<EOF | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  workerConfig:
    configData: |
      core:
      #  labelWhiteList:
      #  noPublish: false
        sleepInterval: 60s
      #  sources: [all]
      #  klog:
      #    addDirHeader: false
      #    alsologtostderr: false
      #    logBacktraceAt:
      #    logtostderr: true
      #    skipHeaders: false
      #    stderrthreshold: 2
      #    v: 0
      #    vmodule:
      ##   NOTE: the following options are not dynamically run-time 
      ##          configurable and require a nfd-worker restart to take effect
      ##          after being changed
      #    logDir:
      #    logFile:
      #    logFileMaxSize: 1800
      #    skipLogHeaders: false
      sources:
      #  cpu:
      #    cpuid:
      ##     NOTE: whitelist has priority over blacklist
      #      attributeBlacklist:
      #        - "BMI1"
      #        - "BMI2"
      #        - "CLMUL"
      #        - "CMOV"
      #        - "CX16"
      #        - "ERMS"
      #        - "F16C"
      #        - "HTT"
      #        - "LZCNT"
      #        - "MMX"
      #        - "MMXEXT"
      #        - "NX"
      #        - "POPCNT"
      #        - "RDRAND"
      #        - "RDSEED"
      #        - "RDTSCP"
      #        - "SGX"
      #        - "SSE"
      #        - "SSE2"
      #        - "SSE3"
      #        - "SSE4.1"
      #        - "SSE4.2"
      #        - "SSSE3"
      #      attributeWhitelist:
      #  kernel:
      #    kconfigFile: "/path/to/kconfig"
      #    configOpts:
      #      - "NO_HZ"
      #      - "X86"
      #      - "DMI"
        pci:
          deviceClassWhitelist:
            - "0200"
            - "03"
            - "12"
          deviceLabelFields:
      #      - "class"
            - "vendor"
      #      - "device"
      #      - "subsystem_vendor"
      #      - "subsystem_device"
      #  usb:
      #    deviceClassWhitelist:
      #      - "0e"
      #      - "ef"
      #      - "fe"
      #      - "ff"
      #    deviceLabelFields:
      #      - "class"
      #      - "vendor"
      #      - "device"
      #  custom:
      #    - name: "my.kernel.feature"
      #      matchOn:
      #        - loadedKMod: ["example_kmod1", "example_kmod2"]
      #    - name: "my.pci.feature"
      #      matchOn:
      #        - pciId:
      #            class: ["0200"]
      #            vendor: ["15b3"]
      #            device: ["1014", "1017"]
      #        - pciId :
      #            vendor: ["8086"]
      #            device: ["1000", "1100"]
      #    - name: "my.usb.feature"
      #      matchOn:
      #        - usbId:
      #          class: ["ff"]
      #          vendor: ["03e7"]
      #          device: ["2485"]
      #        - usbId:
      #          class: ["fe"]
      #          vendor: ["1a6e"]
      #          device: ["089a"]
      #    - name: "my.combined.feature"
      #      matchOn:
      #        - pciId:
      #            vendor: ["15b3"]
      #            device: ["1014", "1017"]
      #          loadedKMod : ["vendor_kmod1", "vendor_kmod2"]
  operand:
    imagePullPolicy: IfNotPresent
    servicePort: 12000
  customConfig:
    configData: |
      #    - name: "more.kernel.features"
      #      matchOn:
      #      - loadedKMod: ["example_kmod3"]
      #    - name: "more.features.by.nodename"
      #      value: customValue
      #      matchOn:
      #      - nodename: ["special-.*-node-.*"]
EOF

# Wait for NFD to be ready
sleep 30
oc get pods -n openshift-nfd

# Verify GPU nodes are labeled
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
```


### 1.3 Install NVIDIA GPU Operator

```bash
# Create namespace 
oc create namespace nvidia-gpu-operator --dry-run=client -o yaml | oc apply -f -

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: v25.10
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator to be ready
sleep 15
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/gpu-operator-certified -n nvidia-gpu-operator --timeout=300s

# Verify CSV
oc get csv -n nvidia-gpu-operator
```


### 1.4 Create ClusterPolicy Instance

```bash
# Create ClusterPolicy to configure GPU support
cat <<EOF | oc apply -f -
kind: ClusterPolicy
apiVersion: nvidia.com/v1
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
    use_ocp_driver_toolkit: true
    initContainer: {}
  cdi:
    enabled: true
  sandboxWorkloads:
    enabled: false
    defaultWorkload: container
  driver:
    enabled: true
    useNvidiaDriverCRD: false
    kernelModuleType: auto
    upgradePolicy:
      autoUpgrade: true
      drain:
        deleteEmptyDir: false
        enable: false
        force: false
        timeoutSeconds: 300
      maxParallelUpgrades: 1
      maxUnavailable: 25%
      podDeletion:
        deleteEmptyDir: false
        force: false
        timeoutSeconds: 300
      waitForCompletion:
        timeoutSeconds: 0
    repoConfig:
      configMapName: ''
    certConfig:
      name: ''
    licensingConfig:
      nlsEnabled: true
      secretName: ''
    virtualTopology:
      config: ''
    kernelModuleConfig:
      name: ''
  dcgmExporter:
    enabled: true
    config:
      name: ''
    serviceMonitor:
      enabled: true
  dcgm:
    enabled: true
  daemonsets:
    updateStrategy: RollingUpdate
    rollingUpdate:
      maxUnavailable: '1'
  devicePlugin:
    enabled: true
    config:
      name: ''
      default: ''
    mps:
      root: /run/nvidia/mps
  gfd:
    enabled: true
  migManager:
    enabled: true
  nodeStatusExporter:
    enabled: true
  mig:
    strategy: single
  toolkit:
    enabled: true
  validator:
    plugin:
      env: []
  vgpuManager:
    enabled: false
  vgpuDeviceManager:
    enabled: true
  sandboxDevicePlugin:
    enabled: true
  vfioManager:
    enabled: true
  gds:
    enabled: false
  gdrcopy:
    enabled: false
EOF

# Wait for ClusterPolicy to be ready (this can take 5-10 minutes)
echo "Waiting for GPU drivers to be deployed (this may take 5-10 minutes)..."
oc wait --for=condition=ready clusterpolicy/gpu-cluster-policy --timeout=600s

# Verify GPU operator pods are running
oc get pods -n nvidia-gpu-operator
```


### 1.5 Verify GPU Access

```bash
# Check GPU nodes have the correct labels
oc get nodes -l nvidia.com/gpu.present=true -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable."nvidia\.com/gpu"
```

---

## Phase 2: Platform Operator Installation

### 2.1 Install cert-manager for Red Hat OpenShift

cert-manager is required for managing TLS certificates for the MaaS platform and model serving.

```bash
# Create namespace for cert-manager
oc create namespace cert-manager-operator --dry-run=client -o yaml | oc apply -f -

# Clean up any existing OperatorGroups (only one allowed per namespace)
oc delete operatorgroup --all -n cert-manager-operator --ignore-not-found=true

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1.18
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator to be ready
sleep 15
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/openshift-cert-manager-operator -n cert-manager-operator --timeout=300s

# Verify CSV
oc get csv -n cert-manager-operator
```

---

### 2.2 Install Red Hat Connectivity Link (RHCL)

Red Hat Connectivity Link (RHCL) is **required** for RHOAI 3.0+ with Service Mesh 3 to provide AuthPolicy CRD support for LLMInferenceService networking and the MaaS platform.

RHCL operator automatically installs the following Kuadrant components:
- **Authorino Operator** - Provides AuthPolicy for authentication/authorization
- **Limitador Operator** - Provides RateLimitPolicy for rate limiting
- **DNS Operator** - Provides DNSPolicy for DNS management

```bash
# Install RHCL operator in openshift-operators namespace
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: rhcl-operator.v1.2.0
EOF

# Wait for install plan to be created
sleep 10

# Find and approve the authorino-operator install plan
INSTALL_PLAN=$(oc get installplan -n openshift-operators -o json | jq -r '.items[] | select(.spec.clusterServiceVersionNames[] | contains("authorino-operator")) | select(.spec.approved == false) | .metadata.name' | head -1)

if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving install plan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
else
  echo "No pending install plan found for authorino-operator"
fi

# Wait for operator to be ready
sleep 15
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/rhcl-operator -n openshift-operators --timeout=300s
```

**Verify RHCL Installation:**

```bash
# Verify all installed operators (RHCL installs 4 operators total)
echo "Installed operators:"
oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns-operator'

# Verify CRDs are available
echo -e "\nAvailable Policy CRDs:"
oc api-resources | grep -E 'AuthPolicy|DNSPolicy|RateLimitPolicy'
```

---

### 2.3 Install Leader Worker Set Operator

```bash
# Create namespace
oc create namespace openshift-lws-operator --dry-run=client -o yaml | oc apply -f -

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-lws-operator
  namespace: openshift-lws-operator
spec:
  targetNamespaces:
  - openshift-lws-operator
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: leader-worker-set
  namespace: openshift-lws-operator
spec:
  channel: stable-v1.0
  installPlanApproval: Automatic
  name: leader-worker-set
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator to be ready
sleep 15
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/leader-worker-set -n openshift-lws-operator --timeout=300s

# Verify CSV
oc get csv -n openshift-lws-operator
```

**Note:** You may see Authorino and Limitador CSVs showing as "Pending" in the `openshift-lws-operator` namespace. This is normal behavior - these are reflected/copied CSVs from `openshift-operators` where RHCL components are actually installed. The actual operators are "Succeeded" in their home namespace. You can verify the actual status with:
```bash
# Check actual RHCL component status in openshift-operators namespace
oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador'
```

---

### 2.4 Install Red Hat OpenShift AI 3

```bash
# Create namespace
oc create namespace redhat-ods-operator --dry-run=client -o yaml | oc apply -f -

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator-group
  namespace: redhat-ods-operator
spec: {}
EOF

# Install RHOAI operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: fast-3.x
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for operator (takes about 60-90 seconds)
sleep 20
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/rhods-operator -n redhat-ods-operator --timeout=300s

sleep 180

# Verify
oc get csv -n redhat-ods-operator

# RedHat Openshift AI 3 automatically installs service mesh operator3 but the install plan needs to be approved
# If an install plan is stuck in Manual approval, approve it
# Get the install plan name (if any)
INSTALL_PLAN=$(oc get installplan -n openshift-operators -o json | jq -r '.items[] | select(.spec.clusterServiceVersionNames[] | contains("servicemeshoperator")) | select(.spec.approved == false) | .metadata.name' | head -1)

if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving install plan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
fi

# Wait for operator
sleep 15
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/servicemeshoperator3 -n openshift-operators --timeout=300s
```

---

## Phase 3: Create DataScienceCluster


### 3.1 Wait for DSCInitialization

```bash
# DSCInitialization is created automatically by RHOAI operator
# Wait 60-90 seconds for it to be created
sleep 60

# Verify it exists and wait for ReconcileComplete
oc get dscinitialization
oc wait --for=condition=ReconcileComplete dscinitialization/default-dsci --timeout=600s
```


### 3.2 Create DataScienceCluster with KServe Only

```bash
# Create DataScienceCluster with ONLY KServe enabled
cat <<EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Removed
    dashboard:
      managementState: Removed
    datasciencepipelines:
      managementState: Removed
    kserve:
      managementState: Managed
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Removed
EOF

oc wait --for=condition=Ready datasciencecluster/default-dsc --timeout=900s
```

### 3.3 Verify All Components

```bash
# 1. Verify DataScienceCluster
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'
# Expected: Ready

# 2. Verify KServe component is enabled
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.managementState}'
# Expected: Managed

# 3. Verify Service Mesh 3 Istio resource
oc get istio openshift-gateway -n openshift-ingress
# Expected: STATUS=Healthy, VERSION=v1.26.2

# 4. Verify GatewayClass for KServe
oc get gatewayclass data-science-gateway-class
# Expected: ACCEPTED=True

# 5. Verify Gateway (created automatically by RHOAI)
oc get gateway -n openshift-ingress data-science-gateway
# Expected: Should exist (PROGRAMMED)

# 6. Verify KServe controller
oc get pods -n redhat-ods-applications | grep kserve-controller
# Expected: kserve-controller-manager running

# 7. Verify Service Mesh operator (version 3)
oc get csv -n redhat-ods-operator | grep servicemeshoperator3
# Expected: servicemeshoperator3.v3.x.x Succeeded

# 8. Verify KServe API resources
oc api-resources | grep kserve.io
```

---

## Phase 4: Deploy and Access Model

### 4.1 Deploy the Model

Deploy the LLMInferenceService using the model manifest:

```bash
# Create llm namespace
oc create namespace llm --dry-run=client -o yaml | oc apply -f -

# Deploy the model
oc apply -f model.yaml

# Wait for the LLMInferenceService to be ready
oc wait --for=condition=Ready llminferenceservice/facebook-opt-125m-simulated -n llm --timeout=300s

# Verify the deployment
oc get llminferenceservice facebook-opt-125m-simulated -n llm
oc get pods -n llm
```

### 4.2 Create Route for External Access

```bash
# Create the route
oc apply -f route.yaml

# Get the route hostname
ROUTE_URL=$(oc get route facebook-opt-125m-simulated -n llm -o jsonpath='{.spec.host}')
echo "Model endpoint: https://${ROUTE_URL}"
```

### 4.3 Access the Model Inference

Make inference requests to the deployed model using the OpenAI-compatible API:

```bash
# Store the route URL
ROUTE_URL=$(oc get route facebook-opt-125m-simulated -n llm -o jsonpath='{.spec.host}')

# Test the health endpoint (should return HTTP 200)
curl -k -w "\nHTTP Status: %{http_code}\n" https://${ROUTE_URL}/health

# Test the readiness endpoint (should return HTTP 200)
curl -k -w "\nHTTP Status: %{http_code}\n" https://${ROUTE_URL}/ready

# Make a completion request
curl -k https://${ROUTE_URL}/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "facebook/opt-125m",
    "prompt": "Once upon a time",
    "max_tokens": 50
  }'

# Make a chat completion request
curl -k https://${ROUTE_URL}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "facebook/opt-125m",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ],
    "max_tokens": 50
  }'
```

---
