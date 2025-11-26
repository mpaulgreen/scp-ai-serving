# OpenShift AI Model Serving Deployment Guides

This repository contains deployment guides and manifests for model serving on OpenShift with Red Hat OpenShift AI (RHOAI).

## Available Deployment Guides

### RHOAI 2.25
Complete deployment guide for Red Hat OpenShift AI 2.25 with KServe model serving.

📖 **Guide:** [bom.md](./bom.md)

---

### RHOAI 3.0.0
Complete deployment guide for Red Hat OpenShift AI 3.0.0 with Service Mesh 3, including GPU support, operator installation, and KServe configuration.

📖 **Guide:** [maas/bom_3.0.0.md](./maas/bom_3.0.0.md)

---

### MaaS Platform (Model-as-a-Service)
MaaS platform deployment with token-based authentication, tier-based access control, and rate limiting.

📖 **Guide:** [maas/README.md](./maas/README.md)

**Features:**
- Token-based authentication via ServiceAccount tokens
- Tier-based access control (free, premium, enterprise)
- Request and token rate limiting
- Gateway API integration
- OpenAI-compatible API endpoints
