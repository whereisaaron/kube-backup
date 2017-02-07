# kube-backup

Utility container for Kubernetes to backup databases and files from other containers.

Available on [Docker Hub](https://hub.docker.com/r/whereisaaron/kube-backup/).

*This is an early prototype. it kinda works. sometimes.*

```
kubectl run -it --rm kube-backup --image whereisaaron/kube-backup --namespace=kube-backup --restart='Never' -- \
 --task=backup-mysql-exec --namespace=default --pod=my-mysql-pod --container=mysql
```

```
Usage:
  kube-backup.sh --task=<task name> [options...]
  kube-backup.sh --task=backup-mysql-exec [--database=<db name>] [options...]
  kube-backup.sh --task=backup-files-exec [--files-path=<files path>] [options...]
    [--pod=<pod-name>|--selector=<selector>] [--container=<container-name>] [--secret=<secret name>]
    [--s3-bucket=<bucket name>] [--s3-prefix=<prefix>] [--aws-secret=<secret name>]
    [--use-kubeconfig-from-secret|--kubeconfig-secret=<secret name>]
    [--slack-secret=<secret name>]
    [--timestamp=<timestamp>] [--backup-name=<backup name>]
    [--dry-run]
  kube-backup.sh --help
  kube-backup.sh --version

  --secret is the default secret for all secrets (kubeconfig, AWS, Slack) 
  --timestamp allows two backups to share the same timestamp
  --s3-bucket if not specified, will be taken from the AWS secret
  --s3-prefix is inserted at the beginning of the S3 prefix
  --backup-name will replace e.g. the database name or file path
  --dry-run will do everything except the actual backup
```
