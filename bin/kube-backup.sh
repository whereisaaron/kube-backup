#!/bin/bash
#
# kube-backup.sh
# Various strategies to back-up the contents of containers running on a Kubernetes cluster.
# Uses kubectl against the Kubernetes API. Can be use internal or external to a cluster.
# Aaron Roydhouse <aaron@roydhouse.com>, 2017
#
# Exit values
# - Success: 0
# - Task failed: 1
# - Error occurred: 2
# - Missing dependancy: 3
#

VERSION=0.1

#
# Utility functions
#

display_usage ()
{
  local script_name="$(basename $0)"
  cat <<END
Usage:
  ${script_name} --task=<task name> [options...]
  ${script_name} --task=backup-mysql-exec [--database=<db name>] [options...]
  ${script_name} --task=backup-files-exec [--files-path=<files path>] [options...]
    [--pod=<pod-name>|--selector=<selector>] [--container=<container-name>] [--secret=<secret name>]
    [--s3-bucket=<bucket name>] [--s3-prefix=<prefix>] [--aws-secret=<secret name>]
    [--use-kubeconfig-from-secret|--kubeconfig-secret=<secret name>]
    [--slack-secret=<secret name>]
    [--timestamp=<timestamp>] [--backup-name=<backup name>]
    [--dry-run]
  ${script_name} --help
  ${script_name} --version

  --secret is the default secret for all secrets (kubeconfig, AWS, Slack) 
  --timestamp allows two backups to share the same timestamp
  --s3-bucket if not specified, will be taken from the AWS secret
  --s3-prefix is inserted at the beginning of the S3 prefix
  --backup-name will replace e.g. the database name or file path
  --dry-run will do everything except the actual backup

END
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

array_contains () {
  local a
  for a in "${@:2}"; do [[ "$a" == "$1" ]] && return 0; done
  return 1
}

#======================================================================
# Find containers
#

# Check a container exists
# Pass the names of the global pod and container variables
# Will update the container variable is empty
check_container ()
{
  local pod_var=$1 container_var=$2
  eval "local pod=\$${pod_var}"
  eval "local container=\$${container_var}"

  if [[ -z "${pod}" ]]; then
    echo "Must specify a pod name"
    display_usage
    return 3
  fi

  local containers=($($KUBECTL get pod $pod $NS_ARG -o jsonpath='{.spec.containers[*].name}' 2> /dev/null))
  if [[ "$?" -eq 0 ]]; then
    if [[ "${#containers[@]}" -gt 0 ]]; then
      echo "Pod '$pod' has ${#containers[@]} containers: ${containers[@]}"
      if [[ -z "$container" ]]; then
        echo "No container specified, using the first container in pod '${pod}': ${containers[0]}"
        container="${containers[0]}"
        eval "${container_var}=$container"
      else
        array_contains $container "${containers[@]}"
        if [[ "$?" -ne 0 ]]; then
          echo "Container '${container}' not found in pod '${pod}'"
          return 3
        else
          echo "Specified container '${container}' found in pod '${pod}'"
        fi
      fi
      # Check the identified pod is ready
      if [[ "true" != $($KUBECTL get pod $pod $NS_ARG -o jsonpath="{.status.containerStatuses[?(@.name == \"${container}\")].ready}") ]]; then
        echo "Container '${container}' in pod '${pod}' is not ready"
        return 3
      fi
    else
      echo "Pod '${pod}' has no containers"
    fi
  else
    echo "Pod '${pod}' not found"
    return 3
  fi
}

# Find all pods matching a selector
# Returns pod names in pods_var
find_pods_with_selector ()
{
  local selector=$1 namespace=$2 pods_var=$3

  if [[ -n "${namespace}" ]]; then
    local ns_arg="--namespace=${namespace}"
  else
    local ns_arg=""
  fi

  local pods=($(kubectl get pod --selector=${selector} $ns_arg -o jsonpath='{.items[*].metadata.name}'))
  if [[ "$?" -eq 0 ]]; then
    if [[ "${#pods[@]}" -gt 0 ]]; then
      echo "Selector '$selector' matched ${#pods[@]} pods: ${pods[@]}"
    else
      echo "The selector '$selector' matched no pods"
    fi
  else
    echo "Error finding pods with selector '$selector'"
    return 1
  fi

  eval "${pods_var}=\"${pods[@]}\""
}

#======================================================================
# Kubernetes secrets
#

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

#======================================================================
# AWS Secrets
#

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
    export AWS_ACCESS_KEY_ID=$(echo "${secrets[0]}" | $BASE64 -d)
    export AWS_SECRET_ACCESS_KEY=$(echo "${secrets[1]}" | $BASE64 -d)
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

# Get AWS S3 settings from a Kubernetes secret 
# Only looks only in the current namespace
get_s3_secret ()
{
  local secret_name=$1

  if [[ -z "${secret_name}" ]]; then
    echo "No S3 secret name specified"
    exit 2
  fi

  local secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.S3_BUCKET}')
  if [[ "$?" -eq 0 ]]; then
    export S3_BUCKET=$(echo "$secret" | $BASE64 -d)
    echo "Fetched S3 bucket name from '$secret_name' secret"
    return 0
  else
    echo "Failed to load S3 bucket from '$secret_name' secret"
    return 1
  fi
}

check_for_s3_secret ()
{
  local secret_name=$1

  if [[ -z "${S3_BUCKET}" ]]; then
    get_s3_secret $secret_name || return 1
  fi
}

#======================================================================
# Slack support
#

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

  local response=$(echo "${body}" | curl -Ss -X POST -H 'Content-type: application/json' --data @- $SLACK_WEBHOOK)

  if [[ "$?" -eq 0 ]]; then
    echo "Sent message to Slack: '$message'"
  else
    echo "Error sending message to Slack: '$response'"
  fi
}

#======================================================================
# Filenames
#

create_filename ()
{
  local pod=$1 container=$2 backup_name=$3 timestamp=$4 ext=$5

  # Have a go at removing the suffix that a Deployment and ReplicaSet adds
  local clean_pod="$(echo ${pod} | sed -e 's/-[0-9]\+-[a-z0-9]\+$//')"

  # Join all non-empty parts
  local filename="${clean_pod}"
  for part in "${container}" "${backup_name}" "${timestamp}"; do
    local clean_part="$(echo ${part} | sed -e 's/[^A-Za-z0-9_-]/_/g' -e 's/__+/_/g' -e 's/^[-_]\+//' -e 's/[-_]$\+//')"
    if [[ -n "${clean_part}" ]]; then
      # If the previous part ends with this part, skip adding (e.g. if pod='foo-website' and container='website')
      if [[ ! "$filename" =~ -${clean_part}$ ]]; then
        filename="${filename}-${clean_part}"
      fi
    fi
  done

  local filename="${filename}${ext}"
  echo "${filename}"
}

#======================================================================
# Backup tasks
#

# This strategy relies on kubectl exec into the offical or derivative MySQL container
# Requires environment variables in container: MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE
# Requires tools in container: bash mysqldump gzip
#
backup_mysql_exec ()
{
  check_container 'POD' 'CONTAINER'
  if [[ "$?" -ne 0 ]]; then
    echo "Aborting backup, no container selected"
    exit $?
  fi

  check_for_s3_secret $AWS_SECRET
  if [[ -n "$S3_BUCKET" ]]; then
    check_for_aws_secret $AWS_SECRET
  fi

  local cmd="${KUBECTL} exec -i ${POD} --container=${CONTAINER} ${NS_ARG} --"

  if [[ -z "${DATABASE}" ]]; then
    echo "No database specified, getting database name from environment of container '$CONTAINER'"
    DATABASE=$($cmd bash -c "echo \"\${MYSQL_DATABASE}\"")
  fi 

  if [[ -z "${DATABASE}" ]]; then
    echo "No database name specified or found"
    exit 3
  fi

  local backup_filename=$(create_filename "${POD}" "${CONTAINER}" "${BACKUP_NAME:-$DATABASE}" "${TIMESTAMP}" ".gz")
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
}

# This strategy relies on kubectl exec into the container
# Requires tools in container: tar gzip
#
backup_files_exec ()
{
  check_container 'POD' 'CONTAINER'
  if [[ "$?" -ne 0 ]]; then
    echo "Aborting backup, no container selected"
    exit $?
  fi

  check_for_s3_secret $AWS_SECRET
  if [[ -n "$S3_BUCKET" ]]; then
    check_for_aws_secret $AWS_SECRET
  fi

  local cmd="${KUBECTL} exec -i ${POD} --container=${CONTAINER} ${NS_ARG} --"

  if [[ -z "${FILES_PATH}" ]]; then
    echo "No backup path specified"
    exit 3
  fi

  local backup_filename=$(create_filename "${POD}" "${CONTAINER}" "${BACKUP_NAME:-$FILES_PATH}" "${TIMESTAMP}" ".tar.gz")
  local backup_cmd="tar czf - '${FILES_PATH}'"

  BACKUP_PATH="${NAMESPACE-default}/${TIMESTAMP}"
  if [[ -n "${S3_BUCKET}" ]]; then
    [[ "$S3_PREFIX" =~ ^/*(.*[^/])/*$ ]] && local prefix=${BASH_REMATCH[1]}; prefix=${prefix}${prefix+/}
    local target="s3://${S3_BUCKET}/${prefix}${BACKUP_PATH}/${backup_filename}"
    echo "Backing up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    if [[ "${DRY_RUN}" != "true" ]]; then
      $cmd bash -c "${backup_cmd}" | ${AWSCLI} s3 cp - "${target}"
      if [[ "$?" -eq 0 ]];then
        send_slack_message "Backed up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
      else
        local msg="Error: Failed to back up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
        send_slack_message "$msg" danger 
        echo "$msg"
      fi
    else
      echo "Skipping backup, dry run delected"
    fi
  else
    local target="${BACKUP_PATH}/${backup_filename}"
    echo "Backing up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    mkdir -p "${BACKUP_PATH}"
    if [[ "${DRY_RUN}" != "true" ]]; then
      $cmd bash -c "${backup_cmd}" > "${target}"
    else
      echo "Skipping backup, dry run delected"
    fi
  fi
}

#======================================================================
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
  --selector=*)
  SELECTOR="${i#*=}"
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
  --files-path=*)
  FILES_PATH="${i#*=}"
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
  --use-kubeconfig-from-secret)
  USE_KUBECONFIG=true
  shift # past argument with no value
  ;;
  --timestamp=*)
  TIMESTAMP="${i#*=}"
  shift # past argument=value
  ;;
  --backup-name=*)
  BACKUP_NAME="${i#*=}"
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

#======================================================================
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
check_tools $KUBECTL $AWSCLI $ENVSUBST $BASE64 sed basename

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
  NS_ARG=""
fi

# Default timestamp for backups
# Setting this in environment or argument allows for multiple backups to be synchronized
: ${TIMESTAMP:=$(date +%Y%m%d-%H%M)}

#======================================================================
# Find pods for tasks
#

if [[ -n "$SELECTOR" ]]; then
  if [[ -n "$POD" ]]; then
    echo "Can only specify a pod name or a selector"
    exit 3
  fi

  PODS=""
  find_pods_with_selector "${SELECTOR}" "${NAMESPACE}" PODS
  if [[ "$?" -ne 0 ]]; then
    exit $?
  fi
  
  POD_ARRAY=($PODS)
  if [[ "${#POD_ARRAY[@]}" -eq 1 ]]; then
    POD="${POD_ARRAY[0]}"
  else
    if [[ "${#POD_ARRAY[@]}" -gt 1 ]]; then
      echo "Selector matched multiple pods, must match only one pod or specify pod name"
      exit 2
    else
      echo "Skipping task, no pods found with selector"
    fi
  fi
fi

#======================================================================
# Run task
#

case $TASK in
  backup-mysql-exec)
    backup_mysql_exec
  ;;
  backup-files-exec)
    backup_files_exec
  ;;
  test-slack)
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

echo "Done"
