# GitOps - Home Lab

Kustomize-based GitOps repository for managing a minikube home lab cluster.

## Structure

```
.
├── base/<app>/                    # Upstream install manifests (cluster-agnostic)
├── overlays/<cluster>/<app>/      # Cluster-specific kustomize + patches
├── apps/<cluster>/                # ArgoCD Application CRs (one per app)
├── app-of-apps/                   # ArgoCD app-of-apps (one per cluster)
└── bootstrap/<cluster>            # Symlink to overlays/<cluster>
```

### Components

| App              | Version | Namespace            | Managed by       |
|------------------|---------|----------------------|------------------|
| Envoy Gateway    | v1.7.0  | envoy-gateway-system | bootstrap + argo |
| ArgoCD           | v3.3.0  | argocd               | bootstrap + argo |
| cert-manager     | v1.19.3 | cert-manager         | argo (helm)      |
| cert-manager CA  |         | cert-manager         | argo (kustomize) |
| k8s-gateway DNS  | v3.4.1  | kube-ingress-dns     | argo (helm)      |

## Bootstrap

```bash
# 1. Bootstrap envoy-gateway and argocd
kubectl apply --server-side -k bootstrap/in-cluster --load-restrictor LoadRestrictionsNone

# 2. Hand control to ArgoCD (deploys all remaining apps and takes over bootstrap apps)
kubectl apply -f app-of-apps/in-cluster.yaml
```

cert-manager and k8s-gateway DNS are not part of the bootstrap — ArgoCD
installs them via Helm charts and handles retries automatically.

## Adding a new cluster

1. Create `overlays/<cluster-name>/` with per-app kustomizations
2. Create `apps/<cluster-name>/` with ArgoCD Application CRs
3. Create `app-of-apps/<cluster-name>.yaml`
4. Create symlink: `ln -s ../overlays/<cluster-name> bootstrap/<cluster-name>`

## Teardown

```bash
kubectl delete -f app-of-apps/in-cluster.yaml
kubectl delete -k bootstrap/in-cluster --load-restrictor LoadRestrictionsNone
```
