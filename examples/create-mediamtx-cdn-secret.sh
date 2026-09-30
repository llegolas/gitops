#!/bin/bash
# Creates the hlsCDNSecret shared by the MediaMTX replicas and the CDN, as
# Secret mediamtx-hls-cdn in namespace mediamtx (replicas) and cdn-sim (PoC
# CDN stand-in). Kept out of GitOps. The same value goes into the real CDN:
#   CloudFront: origin custom header   Authorization: Bearer <secret>
#   Cloudflare: Transform Rule, request header (static)   Authorization: Bearer <secret>
# Refuses to overwrite unless --rotate; after rotating, update the CDNs and:
#   kubectl -n mediamtx rollout restart deploy/mediamtx-replica
#   kubectl -n cdn-sim rollout restart deploy/cdn-sim
set -euo pipefail
NAME=mediamtx-hls-cdn

if kubectl -n mediamtx get secret "$NAME" >/dev/null 2>&1 && [ "${1:-}" != "--rotate" ]; then
  echo "secret mediamtx/$NAME already exists (use --rotate to replace it)" >&2
  exit 1
fi

SECRET=$(openssl rand -hex 32)
for ns in mediamtx cdn-sim; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$ns" create secret generic "$NAME" --from-literal=secret="$SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
done
echo "CDN origin header:  Authorization: Bearer $SECRET"
