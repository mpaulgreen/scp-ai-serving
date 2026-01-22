## Overview

The MaaS platform supports OAuth 2.0 / OpenID Connect (OIDC) authentication using Authorino for token validation. 

**Key Architecture:**
```
User → OAuth Server (get token)
  ↓
User → MaaS Gateway (with JWT token)
  ↓
Authorino → Validate token via JWKS endpoint
  ↓
Extract claims (groups, user info)
  ↓
MaaS API → Tier lookup based on groups
  ↓
Apply tier-based rate limits
```

---

## JWT Token Structure

A JWT (JSON Web Token) consists of three parts separated by dots: `header.payload.signature`

### Complete Token Example

```
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImtleS0yMDI1LTAxIn0.eyJpc3MiOiJodHRwczovL29hdXRoLmV4YW1wbGUuY29tIiwic3ViIjoidXNlci0xMjM0NSIsImF1ZCI6Im1hYXMtY2xpZW50IiwiZXhwIjoxNzMyNjcxNjAwLCJpYXQiOjoxNzMyNjY4NDAwLCJuYmYiOjE3MzI2Njg0MDAsImdyb3VwcyI6WyJ0aWVyLXByZW1pdW0tdXNlcnMiLCJlbmdpbmVlcmluZy10ZWFtIl0sInByZWZlcnJlZF91c2VybmFtZSI6ImpvaG4uZG9lIiwiZW1haWwiOiJqb2huLmRvZUBleGFtcGxlLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJuYW1lIjoiSm9obiBEb2UifQ.signature-part-here
```

### Part 1: Header

```json
{
  "alg": "RS256",              // Signing algorithm (RSA with SHA-256)
  "typ": "JWT",                // Token type
  "kid": "key-2025-01"         // Key ID (identifies which public key to use from JWKS)
}
```

**Purpose:** Tells Authorino which algorithm and key to use for signature verification.

### Part 2: Payload (Claims)

```json
{
  // ========== REQUIRED STANDARD CLAIMS ==========
  "iss": "https://oauth.example.com",       // Issuer - MUST match AuthPolicy issuerUrl
  "sub": "user-12345",                       // Subject - Unique user identifier
  "exp": 1732671600,                         // Expiration - Unix timestamp
  "iat": 1732668400,                         // Issued At - Unix timestamp
  "nbf": 1732668400,                         // Not Before - Unix timestamp (optional)
  "aud": "maas-client",                      // Audience - Token recipient (optional but recommended)

  // ========== REQUIRED FOR MAAS TIER ASSIGNMENT ==========
  "groups": [                                // User groups/roles - CRITICAL for rate limiting
    "tier-premium-users",                    // Must match groups in tier-to-group-mapping ConfigMap
    "engineering-team"                       // Additional groups are fine
  ],

  // ========== RECOMMENDED USER IDENTITY CLAIMS ==========
  "preferred_username": "john.doe",          // Username for display/logging
  "email": "john.doe@example.com",           // User email
  "email_verified": true,                    // Email verification status
  "name": "John Doe",                        // Full name

  // ========== OPTIONAL ADDITIONAL CLAIMS ==========
  "given_name": "John",                      // First name
  "family_name": "Doe",                      // Last name
  "locale": "en-US",                         // User locale
  "picture": "https://example.com/photo.jpg" // Profile picture URL
}
```

### Part 3: Signature

Computed using:
```
signature = RS256(
  base64urlEncode(header) + "." + base64urlEncode(payload),
  private_key_of_oauth_server
)
```

Authorino verifies this signature using the public key fetched from the OAuth server's JWKS endpoint.

---

## Required Claims for MaaS

### Minimum Required Claims

```json
{
  "iss": "https://oauth.example.com",  // Must match AuthPolicy issuerUrl
  "sub": "user-12345",                  // Unique user identifier
  "exp": 1732671600,                    // Token expiration
  "groups": ["tier-premium-users"]      // For tier-based rate limiting
}
```

### Recommended Claims

```json
{
  "iat": 1732668400,                    // Recommended - Token issue time
  "aud": "maas-client",                 // Recommended - Token audience validation
  "preferred_username": "john.doe",     // Recommended - For logging/display
  "email": "john.doe@example.com",      // Recommended - User identification
  "email_verified": true                // Recommended - Security validation
}
```


---
