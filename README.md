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
│   ├── upload-mediamtx-video.sh       # Transcode a local video + copy it into that PVC
│   ├── create-mediamtx-token-secret.sh # Token signing key, /token API key, replica API credentials
│   └── create-mediamtx-cdn-secret.sh  # hlsCDNSecret shared by the replicas and the CDN
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
│   ├── camera-sim/                    # PoC camera simulator (RTSP) + ffmpeg publishers; not part of MediaMTX
│   ├── cdn-sim/                       # PoC CDN stand-in (nginx cache) for CloudFront/Cloudflare; not part of MediaMTX
│   └── mediamtx/                      # Single app, flat resources/ (future Helm chart):
│                                      #   replicas (HLS + WebRTC + API), token service, routes, HLS hash policy, STUNner UDPRoute
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
    ├── camera-sim/
    ├── cdn-sim/
    └── mediamtx/                      # All cluster-specific values (≈ future Helm values)
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
| Camera simulator     | v1.20.0 | mediamtx             | argo (kustomize) | 18        |
| MediaMTX             | v1.20.0 | mediamtx             | argo (kustomize) | 18        |
| CDN simulator        | nginx   | cdn-sim              | argo (kustomize) | 18        |

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
- **Wave 18**: MediaMTX (replicas, token service, HTTPRoutes, STUNner UDPRoute) + PoC camera and CDN simulators

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

Identical, horizontally scaled MediaMTX replicas, each configured with **every** stream: one path per camera, named `<cabinet>/<camera>`, with `sourceOnDemand`. Whichever replica a viewer lands on pulls that camera directly, and only while someone watches — there is no origin (with one WebRTC viewer per stream, an origin would only add a hop; see the [scalability doc](https://mediamtx.org/docs/features/scalability) for the fan-out case). Envoy Gateway replaces Traefik in front, STUNner carries WebRTC media.

```
camera (RTSP) <--pull on demand-- mediamtx-replica x2-3 (all streams, via API)  <-- config service (:9997, headless svc)
viewer --> CDN (cache) --Bearer hlsCDNSecret--> Envoy hls.<domain> (hash by camera) --> mediamtx-replica :8888 HLS
browser --HTTPS--> Envoy webrtc.<domain> (cookie-sticky) --> mediamtx-replica :8889 WHEP signalling
browser --TURN/UDP 30478--> STUNner --UDP--> replica pod IP :8189 (WebRTC media)
```

- **Streams** are programmed by an external config service through each replica's control API (`POST /v3/config/paths/add/<cabinet>/<camera>` with just `{"source": "rtsp://<camera>"}` — `pathDefaults` sets `sourceOnDemand`/`rtspTransport`). API changes live in memory only; the config service watches for new pods and reconciles them. It reaches each pod through the headless `mediamtx-replica-api` Service (`publishNotReadyAddresses`), authenticated with Basic auth (`mediamtx-api-user`/`-password` from the token Secret). For the PoC, `replica.yml` has two static paths instead: WebRTC camera `cabinet1/camera1` (→ camera-sim `bbb`) and HLS camera `hls/cabinet1/camera2` (→ camera-sim `testsrc`).
- **WebRTC**: replicas advertise their pod IP as the ICE host candidate on a fixed UDP port (8189) and hand the STUNner TURN server to browsers (`clientOnly`); the TURN URL is set in the overlay and credentials come from `mediamtx-turn-credentials` via `MTX_WEBRTCICESERVERS2_0_*` env vars.
- **HLS and WebRTC cameras are disjoint.** WebRTC cameras are named `<cabinet>/<camera>`, HLS cameras `hls/<cabinet>/<camera>` — the prefix is what keeps WebRTC cameras off the CDN (see below).
- **WebRTC stickiness** uses Gateway API `sessionPersistence` (cookie `mtx-webrtc`): WHEP sessions live on the replica that created them; Envoy's cookie pins the actual endpoint, so scaling does not reshuffle existing viewers.

#### HLS through a CDN (CloudFront / Cloudflare)

HLS is CDN-only. `hls.<domain>` is the CDN origin; viewers use the CDN URL `/<cabinet>/<camera>/index.m3u8`.

- **MediaMTX** (global settings): `hlsVariant: fmp4` (LL-HLS playlists are `no-cache`), `hlsSegmentDuration: 6s` × `hlsSegmentCount: 30` = the **last 3 minutes**, `hlsCDNSecret` (Secret `mediamtx-hls-cdn`). Requests carrying `Authorization: Bearer <hlsCDNSecret>` skip the cookie check and auth and get cacheable responses: segments/init `public, max-age=3600`, media playlist `max-age=<segment duration>` (6s), multivariant playlist `max-age=30`. Any other HLS playback is denied by the token hook (the static player page is allowed).
- **On demand**: the first CDN request pulls the camera and starts the window; the CDN keeps polling the playlist while anyone watches. 60s after the last request the muxer closes, 10s later the camera is released. RAM per watched HLS camera ≈ 3 min × bitrate (~67 MB at 3 Mbit/s).
- **Envoy** (`httproute-hls.yaml`, `hls-hash-policy.yaml`): rewrites `/<cabinet>/<camera>/…` to `/hls/<cabinet>/<camera>/…` (CDN requests skip auth, so only `hls/` paths are reachable — WebRTC cameras 404/500 there, and the token service refuses `hls/` paths), and a `BackendTrafficPolicy` consistent-hashes on the `X-Mtx-Stream: <cabinet>/<camera>` header the CDN adds (Gateway API can only set static headers, and Lua is disabled in this Envoy Gateway): every request of one camera hits the same replica (segments are per replica — random name prefix, own numbering), so there is **one segment set and one camera pull per HLS camera** regardless of viewers. No cookie stickiness on this route (`Set-Cookie` would stop CDN caching).
- **Scaling** moves ~1/N of the HLS cameras to another replica (their window restarts; players recover on the next playlist reload); the HPA scales down slowly (10 min stabilization).
- **CDN configuration** — the same contract for both:

  | | CloudFront | Cloudflare |
  |---|---|---|
  | Secret to origin | origin custom header `Authorization: Bearer <secret>` | Transform Rule, request header, static `Authorization: Bearer <secret>` |
  | Hash key to origin: `X-Mtx-Stream` = first two path segments (`/cabinet1/camera2/…` → `cabinet1/camera2`) | CloudFront Function (viewer request) sets it; add it to the origin request policy (not the cache key) | Transform Rule, request header, dynamic: `regex_replace(http.request.uri.path, "^/([^/]+/[^/]+)/.*$", "${1}")` — regex availability depends on the plan (else a Worker) |
  | Cache key | URL path only (no cookies / query strings / headers) | same, via Cache Rule |
  | TTL | cache policy honouring origin `Cache-Control` (min 0, max ≥ 3600) | Cache Rule: eligible for cache, Edge TTL = use origin `Cache-Control` |
  | `.m3u8` | cached per policy | **not cached by default** — the Cache Rule must include it |
  | Origin TLS | publicly trusted certificate | same |

  Check Cloudflare's plan terms for serving video through its CDN.
- **PoC CDN** — `base/cdn-sim`, a separate app: nginx at `cdn.minikube.home` implementing that contract (adds the secret and `X-Mtx-Stream` via a `map` on the path, caches by path, honours `Cache-Control`, collapses concurrent misses, `X-Cache: HIT/MISS` header). It skips TLS verification to Envoy (the cluster CA isn't distributed to its namespace).
- **Cameras and HLS**: each HLS camera is pulled by exactly one replica.
- **Camera simulator (PoC only)** — `base/camera-sim`, a separate app: a plain MediaMTX RTSP server that the replicas pull from like a camera. `camera-sim-files` loops every `*.mkv` on the `mediamtx-videos` PVC into it with `-c copy` (subdirectories become part of the name: `cabinet1/camera3.mkv` → `cabinet1/camera3`), `camera-sim-testsrc` publishes a synthetic test pattern as `testsrc`. Opus-in-fMP4 HLS plays in Chrome/Firefox (hls.js); Safari is spotty.

#### WebRTC tokens

WebRTC needs a per-stream token (HLS: see the CDN section above). The replicas use `authMethod: http` with `mediamtx-token` (a standard-library Python script in a ConfigMap, run on stock `python:3.14-slim`, 2 replicas) as the hook: HLS reads are allowed, WebRTC reads need a token issued for exactly that path, control-API calls need the config service's credentials, HLS playback outside the CDN and everything else is denied. `authHTTPExclude` is narrowed to `metrics`/`pprof` — the default also exempts `api`, which would expose the camera URLs and credentials. Tokens are HS256 JWTs, stateless, checked at session start (an expiring token doesn't cut a running session). A frontend coins one and hands it only to the intended viewer:

```bash
curl -s -X POST https://token.minikube.home/token \
  -H "Authorization: Bearer $TOKEN_API_KEY" \
  -d '{"path":"cabinet1/camera1","ttl":300,"viewer":"alice"}'
# -> {"token": "...", "path": "cabinet1/camera1", "expires_at": ..., "whep_url": ".../cabinet1/camera1/whep", "page_url": ".../cabinet1/camera1/?token=..."}
```

The viewer sends `Authorization: Bearer <token>` on its WHEP requests, or opens `page_url` (the built-in player forwards `?token=` to WHEP). TURN credentials (WHEP `Link` header) are only handed out after the token check. Only `POST /token` is routed through Envoy; the `/auth` hook is cluster-internal.

The Secret (token signing key, `/token` API key, replica API credentials) is kept out of GitOps. **Create it before the `mediamtx` app is first synced** — without a running token service the replicas reject every WebRTC viewer and API call:

```bash
examples/create-mediamtx-token-secret.sh   # prints the keys; --rotate to replace (invalidates tokens)
examples/create-mediamtx-cdn-secret.sh     # hlsCDNSecret in mediamtx + cdn-sim; prints the CDN origin header
```

#### Video files (manual, outside GitOps)

The PVC and its contents are kept out of GitOps, same reasoning as the Keycloak realm import: they're data, not config. `camera-sim-files` stays `Pending` until the PVC exists.

```bash
kubectl apply -f examples/mediamtx-videos-pvc.yaml

# e.g. Big Buck Bunny (blender.org only serves it zipped)
curl -fLO https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_normal.mp4.zip
unzip bbb_sunflower_1080p_30fps_normal.mp4.zip
examples/upload-mediamtx-video.sh bbb_sunflower_1080p_30fps_normal.mp4 bbb   # -> rtsp://camera-sim:8554/bbb
```

[examples/upload-mediamtx-video.sh](examples/upload-mediamtx-video.sh) transcodes locally (in the same ffmpeg image the cluster uses) to H264 Constrained Baseline 720p30 with a fixed 2s GOP and Opus audio — MediaMTX does not transcode, and WebRTC needs no B-frames and Opus — then copies the result into the PVC through a throwaway pod and restarts `camera-sim-files`. Serving it needs a replica path with that source (the config service's job; for the PoC, add it to `replica.yml`).

#### Try it

- HLS (via the PoC CDN): `https://cdn.minikube.home/cabinet1/camera2/` (built-in hls.js player; keep the trailing slash) or `https://cdn.minikube.home/cabinet1/camera2/index.m3u8`. `curl -skI` shows `X-Cache: HIT/MISS`. Directly at `hls.minikube.home` playback is denied.
- WebRTC: get a token for `cabinet1/camera1` (above) and open its `page_url` — `chrome://webrtc-internals` should show a relay candidate pair via `192.168.39.135:30478`.
