#!/bin/bash
#
# kube-backup.sh
# Various strategies to back-up the contents of containers running on a Kubernetes cluster.
# Aaron Roydhouse <aaron@roydhouse.com>, 2017
#

VERSION=0.1

#
# Utility functions
#

display_usage ()
{
  local script_name="$(basename $0)"
  echo "Usage:"
  echo "  ${script_name} --task=<task-name> [options...]"
  echo "    [--pod=<pod-name> --container=<container-name>]" 
  echo "    [--s3-bucket=<bucket-name>] [--s3-prefix=<prefix>]"
  echo "    [--timestamp=<timestamp>]"
  echo "    [--dry-run]"
  echo "  ${script_name} --help"
  echo "  ${script_name} --version"
}

display_version ()
{
  local script_name="$(basename $0)"
  echo "${script_name} version ${VERSION}"
}


# Check for essential tools
check_tools ()
{
  for prog in "$@" envsubst; do
    if [ -z "$(which $prog)" ]; then
      echo "Missing dependency '${prog}'"
      echo 10
    fi
  done
}

# Check a container exists
require_container ()
{
  local pod=$1 container=$2

  if [[ -z "${pod}" || -z "${container}" ]]; then
    echo "Must specify a pod name and container name"
    display_usage
    exit 3
  fi
  
  if [[ -z $($KUBECTL get pod $pod $NS_ARG -o jsonpath="{.metadata.name}" 2> /dev/null) ]]; then
    echo "Pod '${pod}' not found"
    exit 20
  fi

  if [[ -z $($KUBECTL get pod $pod $NS_ARG -o jsonpath="{.spec.containers[?(@.name == \"${container}\")].name}") ]]; then
    echo "Container '${container}' not found in pod '${pod}'"
    exit 21
  fi

  if [[ "true" != $($KUBECTL get pod $pod $NS_ARG -o jsonpath="{.status.containerStatuses[?(@.name == \"${container}\")].ready}") ]]; then
    echo "Container '${container}' in pod '${pod}' is not ready"
    exit 22
  fi
}

#
# Backup tasks
#

backup_mysql_exec ()
{
  require_container $POD $CONTAINER

  local cmd="${KUBECTL} exec -i ${POD} --container=${CONTAINER} ${NS_ARG} --"

  if [[ -z "${DATABASE}" ]]; then
    echo "No database specified, getting database name from container environment"
    DATABASE=$($cmd bash -c "echo \"\${MYSQL_DATABASE}\"")
  fi 

  if [[ -z "${DATABASE}" ]]; then
    echo "No database name specified"
    exit 30
  fi

  local backup_filename="${DATABASE}-mysql-database-${TIMESTAMP}.gz"
  local backup_cmd="mysqldump '${DATABASE}' --user=\"\${MYSQL_USER}\" --password=\"\${MYSQL_PASSWORD}\" --single-transaction | gzip"

  BACKUP_PATH="${NAMESPACE-default}/${TIMESTAMP}"
  if [[ -n "${S3_BUCKET}" ]]; then
    [[ "$S3_PREFIX" =~ ^/*(.*[^/])/*$ ]] && local prefix=${BASH_REMATCH[1]}; prefix=${prefix}${prefix+/}
    local target="s3://${S3_BUCKET}/${prefix}${BACKUP_PATH}/${backup_filename}"
    echo "Backing up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    $cmd bash -c "${backup_cmd}" | ${AWSCLI} s3 cp - "${target}"
  else
    local target="${BACKUP_PATH}/${backup_filename}"
    echo "Backing up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    mkdir -p "${BACKUP_PATH}"
    $cmd bash -c "${backup_cmd}" > "${target}"
  fi

  if [[ $? -ne 0 ]]; then
    echo "Failed to complete backup"
    echo 30
  else
    echo "Success"
  fi 

  echo "Done"
}

#
# Parse options
#

for i in "$@"
do
case $i in
  --task=*)
  TASK="${i#*=}"
  shift # past argument=value
  ;;
  --namespace=*)
  NAMESPACE="${i#*=}"
  shift # past argument=value
  ;;
  --pod=*)
  POD="${i#*=}"
  shift # past argument=value
  ;;
  --container=*)
  CONTAINER="${i#*=}"
  shift # past argument=value
  ;;
  --database=*)
  DATABASE="${i#*=}"
  shift # past argument=value
  ;;
  --s3-bucket=*)
  S3_BUCKET="${i#*=}"
  shift # past argument=value
  ;;
  --s3-prefix=*)
  S3_PREFIX="${i#*=}"
  shift # past argument=value
  ;;
  --timestamp=*)
  TIMESTAMP="${i#*=}"
  shift # past argument=value
  ;;
  --dry-run)
  DRY_RUN=true
  shift # past argument with no value
  ;;
  --help)
  display_usage
  exit 0
  ;;
  --version)
  display_version
  exit 0
  ;;
  *)
  # Unknown option
  echo "Unknown option '$1'"
  display_usage
  exit 1
  ;;
esac
done

#
# Check options and environment
#

if [[ -z "$TASK" ]]; then
  echo "No task specified"
  display_usage
  exit 2
fi

: ${KUBECTL:=kubectl}
: ${AWSCLI:=aws}
: ${ENVSUBST:=envsubst}
check_tools $KUBECTL $AWSCLI $ENVSUBST

# Work out the target namespace
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE=$($KUBECTL config view --minify -o jsonpath="{.contexts[0].context.namespace}")
  if [[ -z "${NAMESPACE}" ]]; then
    echo "No namespace specified and no current kubectl context, assuming 'default' namespace"
    NAMESPACE=default
  fi
fi

# Create namespace argument is a namespace has been specified
# Otherwise the current namespace will be used (which is not necessarily 'default')
NS_ARG=${NAMESPACE+--namespace=$NAMESPACE}

# Default timestamp for backups
# Setting this in environment or argument allows for multiple backups to be synchronized
: ${TIMESTAMP:=$(date +%Y%m%d-%H%M)}

# Run task
case $TASK in
  backup-mysql-exec)
  backup_mysql_exec;;
  *)
  # Unknown task
  echo "Unknown task '${TASK}'"
  display_usage
  exit 1
  ;;
esac
