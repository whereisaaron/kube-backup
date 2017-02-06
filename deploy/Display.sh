#!/bin/bash

# Usage:
#   ./Display
#   ./Display -o yaml

kubectl get namespace,secret,clusterrole,clusterrolebinding --selector=app=kube-backup --namespace=kube-backup $@
