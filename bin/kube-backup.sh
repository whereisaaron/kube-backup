#!/bin/bash
#
# kube-backup.sh
# Various strategies to back-up the contents of containers running on a Kubernetes cluster.
# Aaron Roydhouse <aaron@roydhouse.com>, 2017
#
# Exit values
# - Success: 0
# - Task failed: 1
# - Error occured: 2
# - Missing dependancy: 3
#

VERSION=0.1

#
# Utility functions
#

display_usage ()
{
  local script_name="$(basename $0)"
  echo "Usage:"
  echo "  ${script_name} --task=<task name> [options...]"
  echo "    [--pod=<pod-name> --container=<container-name>] [--secret=<secret name>]" 
  echo "    [--s3-bucket=<bucket name>] [--s3-prefix=<prefix>] [--aws-secret=<secret name>]"
  echo "    [--use-kubeconfig|--kubeconfig-secret=<secret name>]"
  echo "    [--slack-secret=<secret name>]"
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
      echo 3
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
    exit 3
  fi

  if [[ -z $($KUBECTL get pod $pod $NS_ARG -o jsonpath="{.spec.containers[?(@.name == \"${container}\")].name}") ]]; then
    echo "Container '${container}' not found in pod '${pod}'"
    exit 3
  fi

  if [[ "true" != $($KUBECTL get pod $pod $NS_ARG -o jsonpath="{.status.containerStatuses[?(@.name == \"${container}\")].ready}") ]]; then
    echo "Container '${container}' in pod '${pod}' is not ready"
    exit 3
  fi
}

get_kubeconfig_secret ()
{
  local secret_name=$1

  if [[ -z "${secret_name}" ]]; then
    echo "No kubeconfig secret name specified"
    exit 3
  fi

  if [[ -r "${HOME}/.kube/config" ]]; then
    echo "kubeconfig file already exists at '${HOME}/.kube/config', not overwriting"
    exit 2
  fi

  local secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.kubeconfig}')
  if [[ "$?" -eq 0 ]]; then
    mkdir -p "${HOME}/.kube"
    touch "${HOME}/.kube/config"; chmod 0600 "${HOME}/.kube/config"
    echo "$secret" | $BASE64 -d > "${HOME}/.kube/config"
    echo "Fetched kubeconfig files from '$secret_name' secret"
  else
    echo "Failed to load kubeconfig from '$secret_name' secret"
    exit 2 
  fi
}

# Get AWS key and secret from a Kubernetes secret 
# Only in the current namespace
get_aws_secret ()
{
  local secret_name=$1

  if [[ -z "${secret_name}" ]]; then
    echo "No AWS secret name specified"
    exit 3
  fi

  local secrets=($($KUBECTL get secret ${secret_name} -o jsonpath='{.data.AWS_ACCESS_KEY_ID} {.data.AWS_SECRET_ACCESS_KEY}'))
  if [[ "$?" -eq 0 ]]; then
    export AWS_ACCESS_KEY_ID=$(echo "$secrets[1]}" | $BASE64 -d)
    export AWS_SECRET_ACCESS_KEY=$(echo "$secrets[2]}" | $BASE64 -d)
    echo "Fetched AWS credientials from '$secret_name' secret"
  else
    echo "Failed to load AWS credentials from '$secret_name' secret"
    exit 2 
  fi
}

check_for_aws_secret ()
{
  local secret_name=$1

  if [[ -z "${AWS_ACCESS_KEY_ID}" ]]; then
    get_aws_secret $secret_name || return 1
  fi
}

# Get Slack webhook URL from a Kubernetes secret 
# Only looks only in the current namespace
get_slack_secret ()
{
  local secret_name=$1

  if [[ -z "${secret_name}" ]]; then
    echo "No Slack secret name specified"
    exit 2
  fi

  local secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.SLACK_WEBHOOK}')
  if [[ "$?" -eq 0 ]]; then
    export SLACK_WEBHOOK=$(echo "$secret" | $BASE64 -d)
    echo "Fetched Slack webhook from '$secret_name' secret"
    return 0
  else
    echo "Failed to load Slack webhook from '$secret_name' secret"
    return 1
  fi
}

check_for_slack_secret ()
{
  local secret_name=$1

  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    get_slack_secret $secret_name || return 1
  fi
}

send_slack_message ()
{
  local message=$1 color=$2

  if [[ -z "${SLACK_WEBHOOK}" || -z "${message}" ]]; then 
    return 
  fi
  : ${color:='good'}

  local body
  read -r -d '' body <<SLACKEND
{
  "attachments": [
    {
      "fallback": "${message}",
      "color": "${color}",
      "text": "${message}"
    }
  ]
}
SLACKEND

  echo "${body}" | curl -X POST -H 'Content-type: application/json' --data @- $SLACK_WEBHOOK

  if [[ "$?" -eq 0 ]]; then
    echo "Sent message to Slack: '$message'"
  else
    echo "Error sending message to Slack: '$message'"
  fi
}

#
# Backup tasks
#

backup_mysql_exec ()
{
  require_container $POD $CONTAINER

  if [[ -n "$S3_BUCKET" ]]; then
    check_for_aws_secret $AWS_SECRET
  fi

  local cmd="${KUBECTL} exec -i ${POD} --container=${CONTAINER} ${NS_ARG} --"

  if [[ -z "${DATABASE}" ]]; then
    echo "No database specified, getting database name from container environment"
    DATABASE=$($cmd bash -c "echo \"\${MYSQL_DATABASE}\"")
  fi 

  if [[ -z "${DATABASE}" ]]; then
    echo "No database name specified"
    exit 3
  fi

  local backup_filename="${DATABASE}-mysql-database-${TIMESTAMP}.gz"
  local backup_cmd="mysqldump '${DATABASE}' --user=\"\${MYSQL_USER}\" --password=\"\${MYSQL_PASSWORD}\" --single-transaction | gzip"

  BACKUP_PATH="${NAMESPACE-default}/${TIMESTAMP}"
  if [[ -n "${S3_BUCKET}" ]]; then
    [[ "$S3_PREFIX" =~ ^/*(.*[^/])/*$ ]] && local prefix=${BASH_REMATCH[1]}; prefix=${prefix}${prefix+/}
    local target="s3://${S3_BUCKET}/${prefix}${BACKUP_PATH}/${backup_filename}"
    echo "Backing up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    if [[ "${DRY_RUN}" != "true" ]]; then
      $cmd bash -c "${backup_cmd}" | ${AWSCLI} s3 cp - "${target}"
      if [[ "$?" -eq 0 ]];then
        send_slack_message "Backed up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
      else
        local msg="Error: Failed to back up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
        send_slack_message "$msg" danger 
        echo "$msg"
      fi
    else
      echo "Skipping backup, dry run delected"
    fi
  else
    local target="${BACKUP_PATH}/${backup_filename}"
    echo "Backing up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    mkdir -p "${BACKUP_PATH}"
    if [[ "${DRY_RUN}" != "true" ]]; then
      $cmd bash -c "${backup_cmd}" > "${target}"
    else
      echo "Skipping backup, dry run delected"
    fi
  fi

  if [[ $? -ne 0 ]]; then
    echo "Failed to complete backup"
    echo 2
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
  --secret=*)
  SECRET="${i#*=}"
  shift # past argument=value
  ;;
  --aws-secret=*)
  AWS_SECRET="${i#*=}"
  shift # past argument=value
  ;;
  --slack-secret=*)
  AWS_SECRET="${i#*=}"
  shift # past argument=value
  ;;
  --kubeconfig-secret=*)
  KUBECONFIG_SECRET="${i#*=}"
  USE_KUBECONFIG=true
  shift # past argument=value
  ;;
  --use-kubeconfig)
  USE_KUBECONFIG=true
  shift # past argument with no value
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
  exit 3
fi

: ${KUBECTL:=kubectl}
: ${AWSCLI:=aws}
: ${ENVSUBST:=envsubst}
: ${BASE64:=base64}
check_tools $KUBECTL $AWSCLI $ENVSUBST $BASE64

# Default secret name is 'kube-backup' in the same namespace
# This is the default secret for all other secrets
# Can be overridden individually
: ${SECRET:=kube-backup}

: ${KUBECONFIG_SECRET:=$SECRET}
if [[ "$USE_KUBECONFIG" == "true" ]]; then
  get_kubeconfig_secret $KUBECONFIG_SECRET
fi

# Only used if an AWS key/secret is not in the environment already
: ${AWS_SECRET:=$SECRET}

# Get optional slack webhook URL
: ${SLACK_SECRET:=$SECRET}
check_for_slack_secret $SLACK_SECRET

# Work out the target namespace
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE=$($KUBECTL config view --minify -o jsonpath="{.contexts[0].context.namespace} 2> /dev/null")
  if [[ -z "${NAMESPACE}" ]]; then
    echo "No task namespace specified"
  fi
fi

# Create namespace argument is a namespace has been specified
# Otherwise the current namespace will be used (which is not necessarily 'default')
if [[ -n "${NAMESPACE}" ]]; then
  NS_ARG=${NAMESPACE+--namespace=$NAMESPACE}
else
  NZ_ARG=""
fi

# Default timestamp for backups
# Setting this in environment or argument allows for multiple backups to be synchronized
: ${TIMESTAMP:=$(date +%Y%m%d-%H%M)}

# Run task
case $TASK in
  backup-mysql-exec)
    backup_mysql_exec
  ;;
  slack-test)
    send_slack_message "Hello world" warning
  ;;
  dump-env)
    env
  ;;
  test-aws)
    check_for_aws_secret $AWS_SECRET
    env
  ;;
  *)
    # Unknown task
    echo "Unknown task '${TASK}'"
    display_usage
    exit 3
  ;;
esac
