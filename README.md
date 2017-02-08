# kube-backup

Utility container to backup databases and files from containers in a Kubernetes cluster. Currently
it can use `kubectl exec` to backup database and files from within containers and store the 
backup files in an AWS S3 bucket.

Docker images are available on [Docker Hub](https://hub.docker.com/r/whereisaaron/kube-backup/).

Source code is available on [Github](https://github.com/whereisaaron/kube-backup). Please
make comments and contribute improvements on Github.

*This is an early prototype, test with care and please report issues or contribute improvements on Github*

## Example use cases

These examples assume you have created a `kube-backup` Secret with AWS credentials and an
S3 bucket name in the namespace where you are running 'kube-backup'. See the 
[deploy directory](https://github.com/whereisaaron/kube-backup/tree/master/deploy)
for an example deployment.

Back up a files using `tar` in a container. It assumes `bash`, `tar`, and `gzip` is available.
```
kubectl run --attach --retart=Never --rm kube-backup --image whereisaaron/kube-backup:0.1.2 -- \
 --task=backup-files-exec --namespace=default --pod=my-pod --container=website --files-path=/var/www
```

Back up a database using `mysqldump` run in the MySQL container. It assumes the environment variables
based on the [offical MySQL container images](https://hub.docker.com/_/mysql/) and that `gzip` is available.
```
kubectl run --attach --restart=Never --rm kube-backup --image whereisaaron/kube-backup:0.1.2 -- \
 --task=backup-mysql-exec --namespace=default --pod=my-pod --container=mysql
```

## Usage

The `kube-backup` container runs the `kube-backup.sh` script. You can supply any
of the following arguments, or set the equivalent (but currently undocumented)
environment variables.
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

Notes:
  --secret is the default secret for all secrets (kubeconfig, AWS, Slack) 
  --timestamp allows two backups to share the same timestamp
  --s3-bucket if not specified, will be taken from the AWS secret
  --s3-prefix is inserted at the beginning of the S3 prefix
  --backup-name will replace e.g. the database name or file path
  --dry-run will do everything except the actual backup
```

## Scripting

You can run or schedule backups of multi-container stateful applications using
a script like below. By synchronising the timestamp for the backups, you can 
ensure the backup files in up in the same directory in S3.

```
#!/bin/bash

#
# Backup MySQL database and website files
# - Use a synchronised timestamp so backups go into the same S3 directory
# - Use randomised deployment names in case any old/stuck deployments exist
#

TIMESTAMP=$(date +%Y%m%d-%H%M)
run_name () { 
  echo "kb-$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 4)" 
}
#EXTRA_OPTS='--dry-run'

CMD='kubectl run --attach --restart=Never --rm --image=whereisaaron/kube-backup:0.1.2 --namespace=kube-backup'

$CMD $(run_name) -- $EXTRA_OPTS \
  --task=backup-mysql-exec \
  --timestamp=${TIMESTAMP} \
  --namespace=default \
  --selector=app=myapp,env=dev,component=mysql 

$CMD $(run_name) -- $EXTRA_OPTS \
  --task=backup-files-exec \
  --timestamp=${TIMESTAMP} \
  --namespace=default \
  --selector=app=myapp,env=dev,component=website \
  --files-path=/var/www/assets \
  --backup-name=assets
```
