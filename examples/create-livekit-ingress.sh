#!/bin/bash
# Registers the RTMP ingress that lets the livekit-rtsp-source pod's feed
# into the "room" room. LiveKit generates a fresh, unique stream key per
# Ingress (there's no way to pin one via the API), so this can't be a static
# manifest -- same reason the Keycloak realm import is a manual step, see
# create-oidc-secret.sh. Re-running this registers a new Ingress each time
# (LiveKit has no upsert-by-name); harmless for a lab, but not idempotent.
set -euo pipefail

API_KEY=access_token
API_SECRET=f14df9af7fc9d6a2b9ccad082c96e8cd67fd9699
LIVEKIT_URL=https://livekit.minikube.home
ROOM=room
IDENTITY=camera-1

TOKEN=$(python3 - "$API_KEY" "$API_SECRET" <<'EOF'
import hmac, hashlib, base64, json, time, sys

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

api_key, api_secret = sys.argv[1], sys.argv[2]
header = {"alg": "HS256", "typ": "JWT"}
now = int(time.time())
payload = {
    "exp": now + 300,
    "iss": api_key,
    "nbf": now,
    "video": {"ingressAdmin": True},
}
signing_input = b64url(json.dumps(header, separators=(',', ':')).encode()) + "." + \
                b64url(json.dumps(payload, separators=(',', ':')).encode())
sig = hmac.new(api_secret.encode(), signing_input.encode(), hashlib.sha256).digest()
print(signing_input + "." + b64url(sig))
EOF
)

RESPONSE=$(curl -sk -w '\n%{http_code}' -X POST "$LIVEKIT_URL/twirp/livekit.Ingress/CreateIngress" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"input_type\":\"RTMP_INPUT\",\"name\":\"rtsp-loop\",\"room_name\":\"$ROOM\",\"participant_identity\":\"$IDENTITY\",\"participant_name\":\"Camera 1\"}")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "CreateIngress failed (HTTP $HTTP_CODE): $BODY" >&2
  exit 1
fi

URL=$(echo "$BODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["url"].rstrip("/") + "/" + d["stream_key"])')

kubectl -n livekit create secret generic livekit-ingress-stream-key \
  --from-literal=url="$URL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Ingress registered, rtmp-relay will pick it up: $URL"
