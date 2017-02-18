#!/bin/bash

# Usage:
#   ./Display.sh
#   ./Display.sh -o yaml

kubectl get namespace,secret,clusterrole,clusterrolebinding --selector=app=kube-backup --namespace=kube-backup $@
