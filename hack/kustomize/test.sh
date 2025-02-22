#!/bin/bash -e
source ../deploy/k8s-utils.sh

# This script automates the functional testing of the collector

function green {
    echo -e $'\e[32m'$1$'\e[0m'
}

function red {
    echo -e $'\e[31m'$1$'\e[0m'
}

function print_msg_and_exit() {
    echo -e "$1"
    exit 1
}

# dumps metrics from a pod into a log file for a given prefix
function dump_metrics() {
    POD=$1
    PREFIX=$2
    OUT=$3
    NAMESPACE=$4

    echo "capturing ${PREFIX} metrics from ${NS}:${POD} into ${OUT}"
    kubectl logs ${POD} -n ${NAMESPACE} | grep "Metric: ${PREFIX}" | jq -r '.msg' >> ${OUT}
}

# validates metrics against a golden copy
function validate_metrics() {
    TYPE=$1
    DUMP=$2
    BASELINE=$3

    sort ${DUMP} > ${SORTED_FILE}

    echo "validating ${TYPE} metrics"

    diff -q ${SORTED_FILE} ${BASELINE}
    if [[ $? -eq 0 ]] ; then
       green "${TYPE} validation succeeded"
    else
       red "${TYPE} validation failed"
    fi
}

function cleanup() {
    rm -f ${PROM_DUMP}
    #TODO: cleanup other files here
}

DEFAULT_VERSION="1.3.3"
DEFAULT_IMAGE_NAME="wavefronthq\/wavefront-kubernetes-collector"

WAVEFRONT_CLUSTER=$1
API_TOKEN=$2
VERSION=$3
IMAGE_NAME=$4


OUT_DIR=/tmp
PROM_DUMP=${OUT_DIR}/prom.txt
SORTED_FILE=${OUT_DIR}/sorted.txt

if [[ -z ${VERSION} ]] ; then
    VERSION=${DEFAULT_VERSION}
fi

if [[ -z ${IMAGE_NAME} ]] ; then
    IMAGE_NAME=${DEFAULT_IMAGE_NAME}
fi

echo "deploying collector ${IMAGE_NAME} ${VERSION}"

env FLUSH_ONCE=true \
./deploy.sh -c ${WAVEFRONT_CLUSTER} -t ${API_TOKEN} -v ${VERSION} -i ${IMAGE_NAME}

echo "deploying configuration for additional targets"

kubectl apply -f ../deploy/mysql-config.yaml
kubectl apply -f ../deploy/memcached-config.yaml

echo "waiting for logs..."
sleep 30

NAMESPACE_VERSION=$(echo "${VERSION}" | tr . -)
NS=${NAMESPACE_VERSION}-wavefront-collector

PODS=`kubectl -n ${NS} get pod -l k8s-app=wavefront-collector | awk '{print $1}' | tail +2`
if [[ -z ${PODS} ]] ; then
    print_msg_and_exit "no collector pods found"
fi

# cleanup existing dumps
cleanup

# TODO: relies on the prefix from the sample app to isolate prom metrics
PROM_PREFIX="prom-example."

wait_for_cluster_ready

for pod in ${PODS} ; do
    dump_metrics ${pod} ${PROM_PREFIX} ${PROM_DUMP} ${NS}
    #TODO: dump_metrics for other prefixes for diff metric sources
done

validate_metrics prometheus ${PROM_DUMP} files/prometheus-baseline.txt
#TODO: add validation for other metric sources

FLUSH_ONCE=false ./deploy.sh -c ${WAVEFRONT_CLUSTER} -t ${API_TOKEN} -v ${VERSION} -i ${IMAGE_NAME}