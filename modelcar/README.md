# ModelCar Deployment Guides

This directory contains guides for deploying AI models as ModelCar (OCI container images) with LLMInferenceService on OpenShift AI.

## What is ModelCar?

ModelCar is a standard format for packaging AI model weights as OCI-compliant container images. Models are bundled into immutable, portable containers that can be deployed anywhere with KServe/OpenShift AI.

## Available Guides

### [tiny_model.md](tiny_model.md) - Small Models (≤3B parameters)

**Use for:** Models under 6GB (e.g., Qwen 2.5 3B, Phi-3 Mini)

**Build approach:** Local download and build on your laptop/Mac

**Key features:**
- Download model locally with HuggingFace CLI
- Build ModelCar with podman
- Push to Quay
- Deploy with LLMInferenceService
- Resources: 1-2 CPU, 12-16Gi memory

---

### [large_model.md](large_model.md) - Large Models (≥8B parameters)

**Use for:** Models over 10GB (e.g., Granite 3.1 8B, Llama 3 8B)

**Build approach:** Build on OpenShift GPU node with buildah

**Key features:**
- Build entirely on OpenShift cluster
- PVC-based storage (no ephemeral limits)
- FP8 quantization for 50% memory savings
- Buildah for container image building
- Resources: 8-16 CPU, 32-64Gi memory

---

## Prerequisites

Both guides require:
- OpenShift cluster with GPU nodes (NVIDIA A10G or better)
- `oc` CLI authenticated
- Quay.io account
- MaaS platform deployed (for authentication & rate limiting)

## Architecture

```
Model Weights (HuggingFace)
    ↓
ModelCar Image (OCI container)
    ↓
Quay Registry
    ↓
LLMInferenceService (OpenShift AI)
    ↓
vLLM Runtime + MaaS Gateway
    ↓
OpenAI-compatible API
```

## Support

For issues or questions, refer to:
- OpenShift AI documentation
- Red Hat ModelCar catalog: https://github.com/redhat-ai-services/modelcar-catalog
