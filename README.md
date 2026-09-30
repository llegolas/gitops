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
│   ├── create-oidc-secret.sh          # OIDC client secret creation
│   ├── mediamtx-videos-pvc.yaml       # PVC for MediaMTX video files (outside GitOps)
│   └── upload-mediamtx-video.sh       # Transcode a local video + copy it into that PVC
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
│   ├── stunner/
│   │   ├── operator/                  # STUNner Helm chart (control plane)
│   │   └── config/                    # GatewayConfig + GatewayClass + Gateway (TURN)
│   └── mediamtx/
│       ├── origin/                    # Single MediaMTX origin (RTSP ingest, cluster-internal)
│       ├── replicas/                  # MediaMTX read replicas (HLS + WebRTC), HPA 2-3
│       ├── source/                    # ffmpeg publishers: looped files from a PVC + test pattern
│       └── route/                     # Sticky HTTPRoutes (HLS, WHEP) + STUNner UDPRoute (media)
└── overlays/<cluster>/
    ├── app-of-apps.yaml               # AppProject + Application CR
    ├── kustomization.yaml             # Lists all app groups
    ├── argocd/
    ├── cert-manager/                  # Aggregates core, ca, trust-manager
    ├── cnpg/                          # Aggregates operator, clusters
    ├── dns-gateway/
    ├── envoy/                         # Aggregates crds, gateway, config
    ├── keycloak/                      # Aggregates operator, server
    ├── stunner/                       # Aggregates operator, config
    └── mediamtx/                      # Aggregates origin, replicas, source, route
```

Each overlay group has a `kustomization.yaml` that aggregates its sub-apps. Sub-apps reference their `base/` counterpart and add cluster-specific patches (hostnames, gateway refs, etc.).

### Components

| App                  | Version | Namespace            | Managed by       | Sync wave |
|----------------------|---------|----------------------|------------------|-----------|
| ArgoCD               | v3.5.0  | argocd               | bootstrap + argo | -         |
| Envoy Gateway        | v1.9.0  | envoy-gateway-system | argo (helm)      | 0         |
| cert-manager         | v1.21.0 | cert-manager         | argo (helm)      | 0         |
| Envoy Gateway config |         | envoy-gateway-system | argo (kustomize) | 1         |
| cert-manager CA      |         | cert-manager         | argo (kustomize) | 1         |
| trust-manager        | v0.24.0 | cert-manager         | argo (helm)      | 0         |
| k8s-gateway DNS      | v3.7.2  | kube-ingress-dns     | argo (helm)      | 2         |
| ArgoCD (self-manage) |         | argocd               | argo (kustomize) | 1         |
| CloudNativePG        | v0.29.0 | cnpg-system          | argo (helm)      | 0         |
| Keycloak operator    | v26.7.0 | keycloak             | argo (kustomize) | 1         |
| Keycloak             | v26.7.0 | keycloak             | argo (kustomize) | 2         |
| STUNner              | v1.2.1  | stunner-system        | argo (helm)      | 10        |
| STUNner config       |         | stunner               | argo (kustomize) | 15        |
| MediaMTX origin      | v1.20.0 | mediamtx             | argo (kustomize) | 18        |
| MediaMTX replicas    | v1.20.0 | mediamtx             | argo (kustomize) | 19        |
| MediaMTX source      |         | mediamtx             | argo (kustomize) | 19        |
| MediaMTX routes      |         | mediamtx             | argo (kustomize) | 20        |

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
- **Wave 10**: STUNner control plane (Helm chart — operator + auth service)
- **Wave 15**: STUNner TURN Gateway config
- **Wave 18**: MediaMTX origin
- **Wave 19**: MediaMTX read replicas + video publishers
- **Wave 20**: MediaMTX HTTPRoutes (HLS, WebRTC/WHEP) + STUNner UDPRoute (WebRTC media)

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

### Keycloak realm (manual import)

Realm `poc` is imported once via a `KeycloakRealmImport` CR. Because Keycloak persists state in PostgreSQL (CNPG), this is applied **manually** and kept out of GitOps.

See [examples/realm-import-poc.yaml](examples/realm-import-poc.yaml) for the full CR. Key points:

- Client: `envoy-gateway-poc` (confidential, standard flow), four redirect URIs — `https://poc.minikube.home/oauth2/callback-{app,admin,api,dashboard}` (one per SecurityPolicy)
- Protocol mapper `groups` — standard `oidc-group-membership-mapper` with `full.path: "false"`, emitting `groups: ["admins", "users"]` etc. in the token.
- Groups: `/admins`, `/developers`, `/users`
- Test users: `admin-user`, `dev-user`, `basic-user` (passwords masked).
- The `KeycloakRealmImport` CR only imports on first creation — if the realm already exists, delete it (`kcadm.sh delete realms/poc` inside `keycloak-0`) or drop the CNPG DB before re-applying.

Apply with: `kubectl apply -f examples/realm-import-poc.yaml`

### MediaMTX (scalable HLS / WebRTC)

Implements the [read replica](https://mediamtx.org/docs/features/scalability) pattern, with Envoy Gateway in place of Traefik and STUNner carrying WebRTC media:

```
ffmpeg (loop) --RTSP--> mediamtx-origin <--RTSP pull (on demand, 1 per replica per path)-- mediamtx-replica x2-3
browser --HTTPS--> Envoy (cookie-sticky) --> mediamtx-replica :8888 HLS / :8889 WHEP signalling
browser --TURN/UDP 30478--> STUNner --UDP--> replica pod IP :8189 (WebRTC media)
```

- **Origin** accepts publishers on any path over RTSP/TCP; it is not exposed outside the cluster.
- **Replicas** proxy every path (`~^(.+)$`) from the origin with `sourceOnDemand`, so the origin sees one reader per replica, not per viewer. They advertise their pod IP as the ICE host candidate on a fixed UDP port (8189) and hand the STUNner TURN server to browsers (`clientOnly`); the TURN URL is set per overlay and credentials come from `mediamtx-turn-credentials` via `MTX_WEBRTCICESERVERS2_0_*` env vars.
- **Stickiness** uses Gateway API `sessionPersistence` (cookie `mtx-hls` / `mtx-webrtc`): HLS muxers and WHEP sessions live on the replica that created them. Envoy's cookie pins the actual endpoint, so scaling does not reshuffle existing viewers.
- **Sources**: `mediamtx-files` loops every `*.mkv` on the `mediamtx-videos` PVC into the origin with `-c copy`, published under the file name (`bbb.mkv` → path `bbb`). `mediamtx-testsrc` publishes a synthetic test pattern as `testsrc` and needs no files. Opus-in-fMP4 HLS plays in Chrome/Firefox (hls.js); Safari is spotty.

#### Video files (manual, outside GitOps)

The PVC and its contents are kept out of GitOps, same reasoning as the Keycloak realm import: they're data, not config. `mediamtx-files` stays `Pending` until the PVC exists.

```bash
kubectl apply -f examples/mediamtx-videos-pvc.yaml

# e.g. Big Buck Bunny (blender.org only serves it zipped)
curl -fLO https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_normal.mp4.zip
unzip bbb_sunflower_1080p_30fps_normal.mp4.zip
examples/upload-mediamtx-video.sh bbb_sunflower_1080p_30fps_normal.mp4 bbb
```

[examples/upload-mediamtx-video.sh](examples/upload-mediamtx-video.sh) transcodes locally (in the same ffmpeg image the cluster uses) to H264 Constrained Baseline 720p30 with a fixed 2s GOP and Opus audio — MediaMTX does not transcode, and WebRTC needs no B-frames and Opus — then copies the result into the PVC through a throwaway pod and restarts `mediamtx-files`.

#### Try it

- HLS: `https://hls.minikube.home/bbb` (built-in hls.js player) or `https://hls.minikube.home/bbb/index.m3u8`
- WebRTC: `https://webrtc.minikube.home/bbb` — `chrome://webrtc-internals` should show a relay candidate pair via `192.168.39.135:30478`
- Same for `testsrc`. HLS needs a cookie-aware client (MediaMTX does a cookie check, and stickiness relies on it) — browsers are fine, plain `curl` needs `-L -c jar -b jar`.
