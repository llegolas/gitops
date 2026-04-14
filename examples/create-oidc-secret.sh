#!/bin/bash
# Create/update the OIDC client secret used by Envoy SecurityPolicy.
# After Keycloak realm import, rotate the secret in Keycloak and run this script.
kubectl -n envoy-keycloak-poc create secret generic keycloak-oidc-client-secret \
  --from-literal=client-secret='***' \
  --dry-run=client -o yaml | kubectl apply -f -
