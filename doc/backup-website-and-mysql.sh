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

CMD='kubectl run --attach --rm --image=whereisaaron/kube-backup:0.1.1 --namespace=kube-backup'

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
