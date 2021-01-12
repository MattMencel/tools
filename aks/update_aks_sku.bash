#!/usr/bin/env bash
set -e
set -o pipefail

usage() {
  echo "AKS clustername, resource group, new sku size, and nodepool to upgrade must be passed as arguments."
  echo -e "\n Defaults to dry-run mode. Add -x to execute."
  echo -e "\nUsage: $0 -n CLUSTERNAME -g RESOURCE_GROUP_NAME -p NODEPOOL -s NEW_VM_SKU_SIZE\n" 1>&2
  exit 1
}

add_pool() {
  echo "== Add Nodepool $2 =="

  local POOLNAME=$(echo $1 | jq -r '.name')

  if $(echo $1 | jq -r '.enableNodePublicIp') == "true"; then
    local ENABLE_PIP="--enable-node-public-ip"
  else
    local ENABLE_PIP=""
  fi

  local DISK_SIZE=$(echo $1 | jq -r '.osDiskSizeGb')
  local MAX=$(echo $1 | jq -r '.maxCount')
  local MIN=$(echo $1 | jq -r '.minCount')
  local MODE=$(echo $1 | jq -r '.mode')

  local NT=$(echo $1 | jq -r '.nodeTaints | .[]?')
  if [[ ${NT} == "" ]]; then
    local NODE_TAINTS=""
  else
    local NODE_TAINTS="--node-taints $(echo $1 | jq -r '.nodeTaints | join(",")') "
  fi

  echo "Adding Pool: $2 ..."
  local COMMAND="az aks nodepool add --name $2 --cluster-name ${CLUSTER} -g ${RSG} --mode ${MODE} --node-vm-size ${SKU} --node-osdisk-size ${DISK_SIZE} --enable-cluster-autoscaler ${ENABLE_PIP} --min-count ${MIN} --max-count ${MAX} ${NODE_TAINTS}"
  if [ "$EXECUTE" = true ]; then
    RESULT=$($COMMAND)
  else
    echo "DRYRUN: ${COMMAND}"
  fi
}

cordon_nodepool_instances() {
  echo "== Cordon Nodepool $1 =="
  local POOLNAME=$(echo $1 | jq -r '.name')
  NODES=$(kubectl get node -l agentpool=${POOLNAME} -o json | jq -r '.items[].metadata.name')
  for NODE in ${NODES}; do
    echo "Cordon $NODE"
    local COMMAND="kubectl cordon ${NODE}"
    if [ "$EXECUTE" = true ]; then
      RESULT=$($COMMAND)
    else
      echo "DRYRUN: ${COMMAND}"
      RESULT=$($COMMAND --dry-run=client)
      echo "${RESULT}"
    fi
  done
}

drain_nodepool_instances() {
  echo "== Drain Nodepool $1 =="
  local POOLNAME=$(echo $1 | jq -r '.name')
  NODES=$(kubectl get node -l agentpool=${POOLNAME} -o json | jq -r '.items[].metadata.name')
  for NODE in ${NODES}; do
    echo "Drain $NODE"
    local COMMAND="kubectl drain ${NODE}  --ignore-daemonsets --delete-emptydir-data --force"
    if [ "$EXECUTE" = true ]; then
      RESULT=$(${COMMAND})
    else
      echo "DRYRUN: ${COMMAND}"
      RESULT=$(${COMMAND} --dry-run=client)
      echo "${RESULT}"
    fi
  done
}

delete_nodepool() {
  echo "== Delete Nodepool $1 =="

  local POOLNAME=$(echo $1 | jq -r '.name')
  local COMMAND="az aks nodepool delete --name ${POOLNAME} --cluster-name ${CLUSTER} -g ${RSG}"
  if [ "$EXECUTE" = true ]; then
    RESULT=$($COMMAND)
  else
    echo "DRYRUN: ${COMMAND}"
  fi
}
# nodepool_exists() {
#   echo "== Check if Migration Nodepool Already Exists =="
#   for POOL in ${NODEPOOLS}; do
#     local POOLNAME=$(echo ${POOL} | jq -r '.name')
#     if [[ ${POOLNAME} == $1 ]]; then
#       echo "Nodepool (${POOLNAME}) already exists. Skipping creation."
#       return 0
#     fi
#   done
#   return 1
# }

# sku_match() {
#   if [[ $(echo ${JSONPOOL} | jq -r '.vmSize') == ${SKU} ]]; then
#     echo "Nodepool $POOL already uses SKU $SKU... skipping..."
#   fi
# }

EXECUTE=false

while getopts :n:g:p:s:x option; do
  case "${option}" in
  n) CLUSTER=${OPTARG} ;;
  g) RSG=${OPTARG} ;;
  p) POOL=${OPTARG} ;;
  s) SKU=${OPTARG} ;;
  x) EXECUTE=true ;;
  *) usage ;;
  esac
done
shift $((OPTIND - 1))

if $EXECUTE; then
  echo "EXECUTE is true!"
else
  echo "EXECUTE is false - Dry Run Mode"
fi

# Pool name limited to 12 characters
TP="tmp${POOL}"
TMPPOOLNAME=$(echo ${TP:0:12})

echo "Validating SKU..."
LOCATION=$(az aks show -g ${RSG} --name ${CLUSTER} -o json | jq -r '.location')
SKU_SEARCH=$(az vm list-skus -l eastus2 -o json | jq -r --arg SKU "$SKU" '.[] | select(.name==$SKU)')
if [[ ${SKU_SEARCH} == "" ]]; then
  echo "SKU ${SKU} is not available in cluster location ${LOCATION}..."
  exit 1
fi

if POOLEXISTS=$(az aks nodepool show -g ${RSG} --cluster-name ${CLUSTER} --name ${POOL} -o json | jq -c); then
  POOLJSON=${POOLEXISTS}

  if [[ $(echo ${POOLJSON} | jq -r '.vmSize') == ${SKU} ]]; then
    echo "Nodepool $POOL is already upgraded to VM SKU ${SKU}... exiting..."
    exit 1
  fi

  if ! $(az aks nodepool show -g ${RSG} --cluster-name ${CLUSTER} --name ${TMPPOOLNAME}); then
    add_pool ${POOLJSON} ${TMPPOOLNAME}
  else
    echo "Migration pool ${TMPPOOLNAME} already exists... skipping creation..."
  fi

  cordon_nodepool_instances ${POOLJSON}

  drain_nodepool_instances ${POOLJSON}

  delete_nodepool ${POOLJSON}

else
  echo "Nodepool $POOL does not exist in cluster $CLUSTER... checking if reverse migration is required..."

  if POOLEXISTS=$(az aks nodepool show -g ${RSG} --cluster-name ${CLUSTER} --name ${TMPPOOLNAME} -o json | jq -c); then
    echo "Ready for reverse migration..."
  else
    echo "Cannot determine what to do with this cluster. It may require manual intervention..."
    exit 1
  fi
fi

echo "Waiting 30 seconds..."
sleep 30
echo "Beginning reverse migration..."

REVERSEPOOLJSON=$(az aks nodepool show -g ${RSG} --cluster-name ${CLUSTER} --name ${TMPPOOLNAME} -o json | jq -c)

if ! $(az aks nodepool show -g ${RSG} --cluster-name ${CLUSTER} --name ${POOL}); then
  echo "Adding ${POOL} back to cluster..."
  add_pool ${REVERSEPOOLJSON} ${POOL}
else
  echo "Pool ${POOL} already exists... skipping creation..."
fi

cordon_nodepool_instances ${REVERSEPOOLJSON}

drain_nodepool_instances ${REVERSEPOOLJSON}

delete_nodepool ${REVERSEPOOLJSON}
