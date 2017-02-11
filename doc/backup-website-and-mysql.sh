#!/bin/bash
set -e

#
# Backup MySQL database and website files
# - Use a synchronised timestamp so backups go into the same S3 directory
# - Use randomised job/pod names in case any concurrent or completed pods exist
#

TIMESTAMP=$(date +%Y%m%d-%H%M)
run_name () { 
  echo "kb-task-$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 4)" 
}
#EXTRA_OPTS='--dry-run'

# The '--attach --rm' allows us to block until completion, you could remove that not wait for completion
CMD='kubectl run --attach --rm --quiet --restart=Never --image=whereisaaron/kube-backup:0.1.4 --namespace=kube-backup'

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
