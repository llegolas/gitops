# GitOps - Home Lab

GitOps repository for managing a minikube home lab cluster.

## Structure

```
.
├── overlays/<cluster>/<app>/      # Cluster-specific kustomize, patches, install manifests
├── apps/<cluster>/                # ArgoCD Application CRs (one per app, with sync waves)
├── app-of-apps/                   # ArgoCD app-of-apps (one per cluster)
└── bootstrap/<cluster>/           # Minimal kustomization to install ArgoCD
```

### Components

| App                  | Version | Namespace            | Managed by       | Sync wave |
|----------------------|---------|----------------------|------------------|-----------|
| ArgoCD               | v3.3.2  | argocd               | bootstrap + argo | -         |
| Envoy Gateway        | v1.7.0  | envoy-gateway-system | argo (helm)      | 0         |
| cert-manager         | v1.19.4 | cert-manager         | argo (helm)      | 0         |
| Envoy Gateway config |         | envoy-gateway-system | argo (kustomize) | 1         |
| cert-manager CA      |         | cert-manager         | argo (kustomize) | 1         |
| k8s-gateway DNS      | v3.4.1  | kube-ingress-dns     | argo (helm)      | 2         |
| ArgoCD (self-manage) |         | argocd               | argo (kustomize) | 1         |

## Bootstrap

```bash
# 1. Bootstrap ArgoCD only
kubectl apply --server-side -k bootstrap/in-cluster

# 2. Hand control to ArgoCD
kubectl apply -f app-of-apps/in-cluster.yaml
```

ArgoCD then installs everything else via sync waves:
- **Wave 0**: Envoy Gateway + cert-manager (Helm charts — installs CRDs + controllers)
- **Wave 1**: Gateway/routes config, CA issuers, ArgoCD self-management
- **Wave 2**: k8s-gateway DNS (needs Gateway API CRDs registered at startup)

## Adding a new cluster

1. Create `bootstrap/<cluster-name>/` with ArgoCD kustomization
2. Create `overlays/<cluster-name>/` with per-app kustomizations
3. Create `apps/<cluster-name>/` with ArgoCD Application CRs
4. Create `app-of-apps/<cluster-name>.yaml`

## Teardown

```bash
# 1. Remove app-of-apps (stops recreating child apps)
kubectl delete -f app-of-apps/in-cluster.yaml

# 2. Delete all child apps (ArgoCD prunes their deployed resources)
kubectl delete app --all -n argocd

# 3. Remove ArgoCD itself
kubectl delete -k bootstrap/in-cluster

# 4. Clean up leftover namespaces
kubectl delete ns cert-manager envoy-gateway-system kube-ingress-dns
```
