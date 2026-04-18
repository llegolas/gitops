# GitOps - Home Lab

GitOps repository for managing a minikube home lab cluster.

Kube-ingress-dns (manged with argocd too) is needed to resolve ingresses, httproutes etc. locally.
Use NetworkManager dispatch script in `/etc/NetworkManager/dispatcher.d/99-minikube.sh` to register the dns running in minikube to the system with `resolvectl`. See [examples/99-minikube.sh](examples/99-minikube.sh).

It is tested to be working on Fedora Linux but your mileage can vary.

## Structure

```
├── examples/                          # Scripts and manifests for manual steps
│   ├── 99-minikube.sh                 # NetworkManager dispatch script for DNS
│   ├── realm-import-poc.yaml          # Keycloak realm import CR
│   └── create-oidc-secret.sh          # OIDC client secret creation
├── base/
│   ├── argocd/                        # Upstream manifests + routes
│   ├── cert-manager/
│   │   ├── core/                      # cert-manager Helm chart
│   │   ├── ca/                        # CA issuers + certificate
│   │   └── trust-manager/             # trust-manager Helm chart
│   ├── cnpg/
│   │   ├── operator/                  # CloudNativePG Helm chart
│   │   └── clusters/                  # CNPG Cluster CRs + secrets
│   ├── dns-gateway/                   # k8s-gateway Helm chart
│   ├── envoy/
│   │   ├── crds/                      # Envoy Gateway CRDs Helm chart
│   │   ├── gateway/                   # Envoy Gateway Helm chart
│   │   └── config/                    # EnvoyProxy + GatewayClass + Gateway
│   ├── keycloak/
│   │   ├── operator/                  # Keycloak operator CRDs + deployment
│   │   └── server/                    # Keycloak CR + DB + route
│   ├── ory/
│   │   ├── infra/                     # CNPG Ory databases
│   │   ├── hydra/                     # Ory Hydra Helm chart
│   │   ├── kratos/                    # Ory Kratos Helm chart
│   │   ├── kratos-ui/                 # Ory Kratos UI Helm chart
│   │   ├── keto/                      # Ory Keto Helm chart
│   │   └── oathkeeper/               # Ory Oathkeeper Helm chart
│   └── poc-apps/                      # PoC backends + routes + policies
└── overlays/<cluster>/
    ├── app-of-apps.yaml               # AppProject + Application CR
    ├── kustomization.yaml             # Lists all app groups
    ├── argocd/
    ├── cert-manager/                  # Aggregates core, ca, trust-manager
    ├── cnpg/                          # Aggregates operator, clusters
    ├── dns-gateway/
    ├── envoy/                         # Aggregates crds, gateway, config
    ├── keycloak/                      # Aggregates operator, server
    ├── ory/                           # Aggregates infra, hydra, kratos, etc.
    └── poc-apps/
```

Each overlay group has a `kustomization.yaml` that aggregates its sub-apps. Sub-apps reference their `base/` counterpart and add cluster-specific patches (hostnames, gateway refs, etc.).

### Components

| App                  | Version | Namespace            | Managed by       | Sync wave |
|----------------------|---------|----------------------|------------------|-----------|
| ArgoCD               | v3.3.2  | argocd               | bootstrap + argo | -         |
| Envoy Gateway        | v1.7.2  | envoy-gateway-system | argo (helm)      | 0         |
| cert-manager         | v1.20.2 | cert-manager         | argo (helm)      | 0         |
| Envoy Gateway config |         | envoy-gateway-system | argo (kustomize) | 1         |
| cert-manager CA      |         | cert-manager         | argo (kustomize) | 1         |
| trust-manager        | v0.22.0 | cert-manager         | argo (helm)      | 0         |
| k8s-gateway DNS      | v3.6.1  | kube-ingress-dns     | argo (helm)      | 2         |
| ArgoCD (self-manage) |         | argocd               | argo (kustomize) | 1         |
| CloudNativePG        | v0.28.0 | cnpg-system          | argo (helm)      | 0         |
| Keycloak operator    | v26.6.0 | keycloak             | argo (kustomize) | 1         |
| Keycloak             | v26.6.0 | keycloak             | argo (kustomize) | 2         |
| Envoy+Keycloak PoC   |         | envoy-keycloak-poc   | argo (kustomize) | 4         |

## Bootstrap

```bash
# 1. Install ArgoCD
kubectl apply --server-side -k overlays/in-cluster/argocd/resources

# 2. Hand control over to ArgoCD
kubectl apply -f overlays/in-cluster/app-of-apps.yaml
```

ArgoCD then installs everything else via sync waves:

- **Wave 0**: Envoy Gateway + cert-manager + trust-manager + CNPG (Helm charts — installs CRDs + controllers)
- **Wave 1**: Gateway/routes config, CA issuers, ArgoCD self-management
- **Wave 2**: k8s-gateway DNS (needs Gateway API CRDs registered at startup), Keycloak CR + CNPG Cluster
- **Wave 4**: Envoy+Keycloak OIDC PoC (backends, HTTPRoutes, SecurityPolicy)

## Adding a new cluster

1. Create `overlays/<cluster-name>/` with per-app kustomizations referencing the shared `base/`
2. Create `overlays/<cluster-name>/app-of-apps.yaml` with AppProject + Application CR pointing to `overlays/<cluster-name>`
3. Create `overlays/<cluster-name>/kustomization.yaml` listing all app subdirectories
4. Bootstrap: `kubectl apply --server-side -k overlays/<cluster-name>/argocd/resources && kubectl apply -f overlays/<cluster-name>/app-of-apps.yaml`

## Teardown

```bash
# 1. Remove app-of-apps (stops recreating child apps)
kubectl delete -f overlays/in-cluster/app-of-apps.yaml

# 2. Delete all child apps (ArgoCD prunes their deployed resources)
kubectl delete app --all -n argocd

# 3. Remove ArgoCD itself
kubectl delete -k overlays/in-cluster/argocd/resources

# 4. Clean up leftover namespaces
kubectl delete ns cert-manager envoy-gateway-system kube-ingress-dns
```

## Envoy Gateway + Keycloak OIDC PoC

Namespace `envoy-keycloak-poc`. Demonstrates OIDC SSO with group-based authorization via per-route `SecurityPolicy`.

- **Backends**: 5x `ealen/echo-server` (admin, api, dashboard, app, public) on port 8080
- **Public HTTPRoute** `poc-public-routes` (`poc.minikube.home`): `/`, `/health`, `/docs` → `public-service` (no SecurityPolicy)
- **Per-auth-group HTTPRoutes** on `poc.minikube.home`, each paired with its own `SecurityPolicy`. Each HTTPRoute owns a **unique OIDC callback+logout path** (`/oauth2/callback-<group>`, `/oauth2/logout-<group>`) so Keycloak's redirect lands back on the same filter instance that initiated the flow — otherwise the per-policy HMAC secret would reject the CSRF token and the auth code exchange would fail:
  - `poc-app-route`: `/app` + `/oauth2/callback-app` + `/oauth2/logout-app` → `app-service` — SecurityPolicy `oidc-app` (any authenticated user)
  - `poc-admin-route`: `/admin` + `/oauth2/callback-admin` + `/oauth2/logout-admin` → `admin-service` — SecurityPolicy `oidc-admin` (group `admins`)
  - `poc-api-route`: `/api` + `/oauth2/callback-api` + `/oauth2/logout-api` → `api-service` — SecurityPolicy `oidc-api` (group `developers` or `admins`)
  - `poc-dashboard-route`: `/dashboard` + `/oauth2/callback-dashboard` + `/oauth2/logout-dashboard` → `dashboard-service` — SecurityPolicy `oidc-dashboard` (group `users`)
- Group gating uses `SecurityPolicy.spec.authorization.rules` with `principal.jwt.claims` (matches directly against the JWT `groups` array claim). `defaultAction: Deny` returns 403 for principals without the allowed group — no HTTPRoute header-regex rules, no `HTTPRouteFilter` fallbacks.
- Each SecurityPolicy forwards `preferred_username` → `x-user` and `email` → `x-email` via `claimToHeaders`, so backends see who's logged in. `x-jwt-groups` is not forwarded (authz handles the check; Envoy's `claimToHeaders` base64-encodes JSON-array claims anyway).
- **Cross-route session reuse**: all four policies share `cookieDomain: minikube.home` and `cookieNames.accessToken: keycloak-access-token`, and the JWT provider reads the token via `extractFrom.cookies`. Once any policy authenticates, the access-token cookie is readable by the others and JWT authz passes without a new login round-trip (Keycloak SSO handles the rest transparently).
- **TLS trust for OIDC discovery**: Envoy's OIDC/JWT filters reach Keycloak over HTTPS (`https://keycloak.minikube.home`). The self-signed `ca-issuer` CA is distributed via a **trust-manager `Bundle`** that reads the `minikube-home-ca` Secret in `cert-manager` and materializes a `ConfigMap minikube-home-ca` in `envoy-keycloak-poc`. A Gateway API `BackendTLSPolicy` (`keycloak-external-tls`) validates the Envoy `Backend keycloak-external` (`keycloak.minikube.home:443`) against that ConfigMap. Each SecurityPolicy references the `Backend` via `backendRefs.{group: gateway.envoyproxy.io, kind: Backend}`.

### Keycloak realm (manual import)

Realm `poc` is imported once via a `KeycloakRealmImport` CR. Because Keycloak persists state in PostgreSQL (CNPG), this is applied **manually** and kept out of GitOps.

See [examples/realm-import-poc.yaml](examples/realm-import-poc.yaml) for the full CR. Key points:

- Client: `envoy-gateway-poc` (confidential, standard flow), four redirect URIs — `https://poc.minikube.home/oauth2/callback-{app,admin,api,dashboard}` (one per SecurityPolicy)
- Protocol mapper `groups` — standard `oidc-group-membership-mapper` with `full.path: "false"`, emitting `groups: ["admins", "users"]` etc. in the token.
- Groups: `/admins`, `/developers`, `/users`
- Test users: `admin-user`, `dev-user`, `basic-user` (passwords masked).
- The `KeycloakRealmImport` CR only imports on first creation — if the realm already exists, delete it (`kcadm.sh delete realms/poc` inside `keycloak-0`) or drop the CNPG DB before re-applying.

Apply with: `kubectl apply -f examples/realm-import-poc.yaml`

### OIDC client secret (manual)

The OIDC client secret used by the Envoy `SecurityPolicy` is **not** stored in GitOps. After realm import, rotate it in Keycloak and run [examples/create-oidc-secret.sh](examples/create-oidc-secret.sh).

## Ory Stack

Namespace `ory`. Exploring the Ory ecosystem as an alternative/complement to Keycloak for identity and access management.

### Deployed components

| Component   | Role                                                  |
|-------------|-------------------------------------------------------|
| Kratos      | Identity management (registration, login, recovery)   |
| Kratos UI   | Self-service UI for Kratos flows                      |
| Hydra       | OAuth2 / OpenID Connect provider                      |
| Keto        | Permission / authorization service (Zanzibar-style)   |
| Oathkeeper  | Identity-aware reverse proxy (authn/authz decisions)  |
| Infra       | CNPG databases for Hydra, Kratos, and Keto            |

All Helm charts are deployed from `k8s.ory.sh/helm/charts` at version `0.61.1`. Each component has its own CNPG database in the `keycloak` namespace (shared CNPG cluster).

### Planned experiments

- **Kratos self-service flows**: registration, login, password recovery, and settings via Kratos UI (`ory.{cluster-domain}/login`, `/registration`, etc.)
- **Hydra as OAuth2/OIDC provider**: replace or complement Keycloak for issuing tokens — consent/login flows backed by Kratos
- **Oathkeeper as API gateway decision engine**: JWT validation, access rule matching, and header mutation as an alternative to Envoy Gateway SecurityPolicy
- **Keto authorization**: fine-grained permission checks (Zanzibar-style relation tuples) for group/role-based access control
- **End-to-end flow**: Kratos handles identity → Hydra issues tokens → Oathkeeper enforces access rules → Keto checks permissions
