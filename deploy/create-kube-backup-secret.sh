#!/bin/bash
set -e

: ${SLACK_WEBHOOK?"Must define SLACK_WEBHOOK"}
: ${AWS_ACCESS_KEY_ID?"Must define AWS_ACCESS_KEY_ID"}
: ${AWS_SECRET_ACCESS_KEY?"Must define AWS_SECRET_ACCESS_KEY"}

if [[ -n "$S3_BUCKET" ]]; then
  S3_SECRET_ITEM="S3_BUCKET: $(echo -n "${S3_BUCKET}" | base64 -w 0)"
fi

: ${KUBECONFIG_FILE:=kubeconfig}
if [[ ! -r "${KUBECONFIG_FILE}" ]]; then
  echo "kubeconfig file '${KUBECONFIG_FILE}' is missing"
  exit 1
fi

: ${SECRET_NAME:=kube-backup}
: ${SECRET_ENV:=system}
: ${NAMESPACES:=kube-backup}
# Optionally create secret in all namespaces
#NAMESPACES="$(kubectl get namespace -o jsonpath='{..name}')"

for n in $NAMESPACES
do 
  if [[ "$(kubectl get secret $SECRET_NAME --namespace=$n --output name 2> /dev/null || true)" = "secret/${SECRET_NAME}" ]]; then
    ACTION=replace
  else
    ACTION=create
  fi

  kubectl $ACTION --namespace $n -f - <<END
apiVersion: v1
kind: Secret
type: kubernetes.io/opaque
metadata:
  name: $SECRET_NAME
  labels:
    app: kube-backup
    env: $SECRET_ENV
data:
  SLACK_WEBHOOK: $(echo -n "${SLACK_WEBHOOK}" | base64 -w 0)
  AWS_ACCESS_KEY_ID: $(echo -n "${AWS_ACCESS_KEY_ID}" | base64 -w 0)
  AWS_SECRET_ACCESS_KEY: $(echo -n "${AWS_SECRET_ACCESS_KEY}" | base64 -w 0)
  kubeconfig: $(cat "${KUBECONFIG_FILE}" | base64 -w 0)
  ${S3_SECRET_ITEM}
END

done
