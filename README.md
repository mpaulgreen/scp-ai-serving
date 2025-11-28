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

### MaaS Platform Gateway (Model-as-a-Service)
MaaS platform deployment with token-based authentication, tier-based access control, and rate limiting.
Currently Maas Platform needs separate installation as it is not integrated with Operator yet.

[Reference](https://docs.google.com/document/d/1KdyoBZGHS6cIBJjEfjLCBhI8fRB-rGXQsWfQGGuy3lc/edit?tab=t.0#heading=h.595hahs0zq0y)

📖 **Guide:** [maas/README.md](./maas/README.md)

**Features:**
- Token-based authentication via ServiceAccount tokens
- Tier-based access control (free, premium, enterprise)
- Request and token rate limiting
- Gateway API integration
- OpenAI-compatible API endpoints

---

### OAuth POC with Keycloak
OAuth 2.0 / OpenID Connect authentication integration for MaaS platform using Keycloak as the identity and authentication provider.

📖 **Guide:** [oauth_poc/README.md](./oauth_poc/README.md)

📋 **Claim Requirements:** [claim_requirement.md](./oauth_poc/claim_requirement.md)

**Features:**
- OAuth 2.0 / OIDC authentication with Keycloak
- JWT token validation via Authorino
- Request rate limiting based on user tier

**Components:**
- Red Hat SSO (Keycloak) operator and instance
- Keycloak realm and client configuration
- **MaaS platform with OAuth integration**
- Authorino for JWT validation
- Limitador for rate limiting

---

### BYOM Samples
Bring Your Own Model (BYOM) deployment guides for packaging AI models as ModelCar images and deploying them with LLMInferenceService on OpenShift AI.

📖 **Guide:** [modelcar/README.md](./modelcar/README.md)

**Features:**
- ModelCar (OCI container) packaging for AI models
- Deployment guides for small (≤3B) and large (≥8B) models
