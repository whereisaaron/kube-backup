# kube-backup

Utility container for Kubernetes to backup databases and files from other containers.

Available on [Docker Hub](https://hub.docker.com/r/whereisaaron/kube-backup/).

*This is an early prototype - it kinda works at best*

```
kubectl run -it --rm kube-backup --image whereisaaron/kube-backup --namespace=kube-backup --restart='Never' -- \
 --task=backup-mysql-exec --namespace=default --pod=my-mysql-pod --container=mysql
```

```
Usage:
  kube-backup.sh --task=<task name> [options...]
    [--pod=<pod-name> --container=<container-name>] [--secret=<secret name>]
    [--s3-bucket=<bucket name>] [--s3-prefix=<prefix>] [--aws-secret=<secret name>]
    [--use-kubeconfig|--kubeconfig-secret=<secret name>]
    [--slack-secret=<secret name>]
    [--timestamp=<timestamp>]
    [--dry-run]
  kube-backup.sh --help
  kube-backup.sh --version
```
