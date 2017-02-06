#!/bin/bash
set -e
#if [[ $(kubectl get namespace kube-backup -o name) != "namespace/kube-backup" ]]; then
  kubectl apply -f kube-backup-namespace.yaml
#else
#  echo "Namespace 'kube-backup' exists"
#fi
kubectl apply -f kube-backup-rbac.yaml
./create-kube-backup-secret.sh
