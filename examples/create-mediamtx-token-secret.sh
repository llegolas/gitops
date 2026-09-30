#!/bin/bash
# Creates the mediamtx-token-secrets Secret. Kept out of GitOps:
#   signing-key            HMAC key for viewer tokens
#   token-api-key          Bearer key frontends use for POST /token
#   mediamtx-api-user/     Basic-auth credentials the config service uses for
#   mediamtx-api-password  the replicas' control API (:9997)
# Refuses to overwrite an existing Secret: a new signing key invalidates every
# issued token, new keys lock out the frontends/config service -- pass
# --rotate to do it anyway, then restart the service:
#   kubectl -n mediamtx rollout restart deploy/mediamtx-token
set -euo pipefail
NS=mediamtx
NAME=mediamtx-token-secrets

if kubectl -n "$NS" get secret "$NAME" >/dev/null 2>&1 && [ "${1:-}" != "--rotate" ]; then
  echo "secret $NS/$NAME already exists (use --rotate to replace it)" >&2
  exit 1
fi

kubectl -n "$NS" create secret generic "$NAME" \
  --from-literal=signing-key="$(openssl rand -base64 48)" \
  --from-literal=token-api-key="$(openssl rand -hex 32)" \
  --from-literal=mediamtx-api-user=config-service \
  --from-literal=mediamtx-api-password="$(openssl rand -hex 24)" \
  --dry-run=client -o yaml | kubectl apply -f -

get() { kubectl -n "$NS" get secret "$NAME" -o jsonpath="{.data.$1}" | base64 -d; }
echo "POST https://token.minikube.home/token  ->  Authorization: Bearer $(get token-api-key)"
echo "replica control API (:9997)             ->  $(get mediamtx-api-user):$(get mediamtx-api-password)"
