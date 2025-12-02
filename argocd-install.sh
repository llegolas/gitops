#!/bin/bash

set -euo pipefail

DIRNAME=$(dirname $0)
HELM_VERSION=5.51.0
CRD_VERSION=v2.10.5

if [ -z ${ARGOCD_NS+x} ];then
  ARGOCD_NS='argocd'
fi

if [ ! -z ${1+x} ]; then
  if [ -d $1 ]; then
    DIRNAME=$1  
  else
    echo "ERROR: Config directory $1 does not exist"
    exit 1
  fi
fi

VALUES_FILE="${DIRNAME}/values.yaml"

if [ ! -f $VALUES_FILE ]; then
  echo "ERROR: Config file $VALUES_FILE does not exists"
  exit 1
fi

echo "INFO: Using values file $VALUES_FILE"

echo "INFO: Argocd will be installed in $ARGOCD_NS namespace with values file $VALUES_FILE"
if [ "${1-}" == "-y" ] || [ "${1-}" == "--yes" ]; then
  kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=${CRD_VERSION}"
  helm upgrade --install argocd argo/argo-cd \
    --namespace=$ARGOCD_NS \
    --version $HELM_VERSION \
    --create-namespace \
    -f $VALUES_FILE
else
  echo "INFO: Dry-run. Exiting without action. Use -y or --yes to install."
  exit 0
fi
