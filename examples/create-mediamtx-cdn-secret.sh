#!/bin/bash
# Creates the hlsCDNSecret shared by the MediaMTX replicas and the CDN, as
# Secret mediamtx-hls-cdn in namespace mediamtx (replicas) and cdn-sim (PoC
# CDN stand-in). Kept out of GitOps. The same value goes into the real CDN:
#   CloudFront: origin custom header   Authorization: Bearer <secret>
#   Cloudflare: Transform Rule, request header (static)   Authorization: Bearer <secret>
# Refuses to overwrite unless --rotate (if only one namespace still has the
# Secret, the other is restored from it); after rotating, update the CDNs and:
#   kubectl -n mediamtx rollout restart deploy/mediamtx-replica
#   kubectl -n cdn-sim rollout restart deploy/cdn-sim
set -euo pipefail
NAME=mediamtx-hls-cdn

get() { kubectl -n "$1" get secret "$NAME" -o jsonpath='{.data.secret}' 2>/dev/null | base64 -d; }
CUR_MTX=$(get mediamtx || true)
CUR_CDN=$(get cdn-sim || true)

if [ "${1:-}" = "--rotate" ] || [ -z "$CUR_MTX$CUR_CDN" ]; then
  SECRET=$(openssl rand -hex 32)
elif [ -n "$CUR_MTX" ] && [ -n "$CUR_CDN" ]; then
  echo "secret $NAME already exists in mediamtx and cdn-sim (use --rotate to replace it)" >&2
  exit 1
else
  # Only one copy is left (e.g. a namespace was recreated): restore the other
  # from it instead of rotating, so the value the CDN sends stays valid.
  SECRET=${CUR_MTX:-$CUR_CDN}
  echo "restoring the missing copy of $NAME from the existing one" >&2
fi

for ns in mediamtx cdn-sim; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$ns" create secret generic "$NAME" --from-literal=secret="$SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
done
echo "CDN origin header:  Authorization: Bearer $SECRET"
