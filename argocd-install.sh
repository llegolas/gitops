#!/bin/bash
DIRNAME=$(dirname $0)
HELM_VERSION=8.3.3

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
echo -n "Do you want to proceed? [y/n]: "
read ans
if [ "$ans" == "y" ]; then
  kubectl kustomize https://github.com/argoproj/argo-cd.git/manifests/crds/ | kubectl apply -f -
  helm upgrade --install argocd argo/argo-cd \
    --namespace=$ARGOCD_NS \
    --version $HELM_VERSION \
    --create-namespace \
    -f $VALUES_FILE
else
  echo "INFO: Exiting without action"
  exit 0
fi
