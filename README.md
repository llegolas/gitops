# GitOps - Home Lab

GitOps repository for managing a minikube home lab cluster.

Kube-ingress-dns (manged with argocd too) is needed to resolve ingresses, httproutes etc. locally.
Use NetworkManager dispatch script in `/etc/NetworkManager/dispatcher.d/99-minikube.sh` to register the dns running in minikube to the system with `resolvectl`
```

#!/bin/bash -x
echo $@
IFACE=$(virsh -q -l /dev/null domiflist minikube | grep mk-minikube | awk '{print $1}')
BRIDGE=$(virsh -q -l /dev/null net-info mk-minikube | grep Bridge | awk '{print $2}')
MINIKUBE_IP=""

if [ "$1" == "$IFACE" ] && [ "$2" == "up" ]; then
    while [ "$MINIKUBE_IP" == "" ]; do
	    sleep 3
	    MINIKUBE_IP=$(virsh -q -l /dev/null net-dhcp-leases mk-minikube | awk '{print $5}' | cut -d/ -f1)
    done
    resolvectl domain "$BRIDGE" ~minikube.home
    resolvectl dns "$BRIDGE" "$MINIKUBE_IP:30053"
elif [ "$IFACE" == "-"   ] && [ "$2" == "down" ]; then
    resolvectl revert "$BRIDGE"
fi

exit 0
```
It is tested to be working on Fedora Linux but your mileage can vary.

## Structure

```
.
├── base/<app>/                    # Should contain kustomization.yaml and server agnostic resources
├── bootstrap/<cluster>/           # Minimal kustomization to install ArgoCD and app-of-apps.yaml which installs everything else
├── apps/<cluster>/                # ArgoCD Application CRs (one per app, with sync waves)
└── overlays/<cluster>/<app>/      # Cluster-specific kustomize patches and/or install manifests. It could pull resources from ../../../base/<app>
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
kubectl apply --server-side -k bootstrap/in-cluster/01_argocd

# 2. Hand the control over to ArgoCD
kubectl apply -f bootstrap/in-cluster/02_app-of-apps.yaml
```

ArgoCD then installs everything else via sync waves:
- **Wave 0**: Envoy Gateway + cert-manager (Helm charts — installs CRDs + controllers)
- **Wave 1**: Gateway/routes config, CA issuers, ArgoCD self-management
- **Wave 2**: k8s-gateway DNS (needs Gateway API CRDs registered at startup)

## Adding a new cluster

1. Create `bootstrap/<cluster-name>/` with ArgoCD kustomization
2. Create `overlays/<cluster-name>/` with per-app kustomizations
3. Create `apps/<cluster-name>/` with ArgoCD Application CRs
4. Create `bootstrap/<cluster-name>/01_argocd` folder with `install.yaml` and `kustomization.yaml` files 
5. Create `bootstrap/<cluster-name>/02_app-of-apps.yaml`

## Teardown

```bash
# 1. Remove app-of-apps (stops recreating child apps)
kubectl delete -f app-of-apps/in-cluster.yaml

# 2. Delete all child apps (ArgoCD prunes their deployed resources)
kubectl delete app --all -n argocd

# 3. Remove ArgoCD itself
kubectl delete -k bootstrap/in-cluster/01_argocd

# 4. Clean up leftover namespaces
kubectl delete ns cert-manager envoy-gateway-system kube-ingress-dns
```
