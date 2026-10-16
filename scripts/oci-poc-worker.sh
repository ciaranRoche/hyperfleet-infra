#!/usr/bin/env bash
set -euo pipefail
# Launch RHCOS workers for a platform None hosted cluster into a customer VCN
# of the OCI POC environment, approve their CSRs, and terminate them. On None
# HyperShift creates no machines: the NodePool only produces an Ignition stub
# with a bearer token, and the machine-approver cannot approve CSRs because it
# matches them against Machine objects. This script does both by hand.
#
# Usage:
#   scripts/oci-poc-worker.sh <launch|approve|list|terminate> [name...]
#
#   launch NAME...     launch instances with the NodePool's user-data
#   approve            approve pending kubelet CSRs whose node name has NAME_PREFIX
#   list               instances with NAME_PREFIX in the compartment
#   terminate NAME...  terminate instances and their boot volumes; delete the
#                      Node objects too when GUEST_KUBECONFIG is set
#
# Required:
#   OCI_COMPARTMENT_ID   customer compartment
#   SUBNET_ID            customer workers subnet (launch)
#   NSG_ID               customer workers NSG (launch)
#   IMAGE_ID             RHCOS oraclecloud custom image (launch); use the image
#                        whose stream matches the NodePool (rhel-9 by default on 4.x)
#   MGMT_KUBECONFIG      management cluster (launch reads the user-data secret)
#   GUEST_KUBECONFIG     hosted cluster admin kubeconfig (approve)
# Optional:
#   CLUSTER_NAME         (default: demo1)
#   NODEPOOL             (default: demo1-workers)
#   NAMESPACE            HostedCluster namespace (default: clusters)
#   NAME_PREFIX          (default: CLUSTER_NAME-worker-)
#   SHAPE, OCPUS, MEMORY_GB, BOOT_VOLUME_GB (default: VM.Standard.E5.Flex, 4, 16, 120)
#   AVAILABILITY_DOMAIN  (default: first in the tenancy region)
#   OWNER_TAG            (default: $USER)
#   WORKDIR              where the user-data file is written, mode 0600
#                        (default: ~/.cache/oci-poc-worker)

ACTION="${1:-}"; shift || true
OCI_COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
NSG_ID="${NSG_ID:-}"
IMAGE_ID="${IMAGE_ID:-}"
MGMT_KUBECONFIG="${MGMT_KUBECONFIG:-}"
GUEST_KUBECONFIG="${GUEST_KUBECONFIG:-}"
CLUSTER_NAME="${CLUSTER_NAME:-demo1}"
NODEPOOL="${NODEPOOL:-${CLUSTER_NAME}-workers}"
NAMESPACE="${NAMESPACE:-clusters}"
NAME_PREFIX="${NAME_PREFIX:-${CLUSTER_NAME}-worker-}"
SHAPE="${SHAPE:-VM.Standard.E5.Flex}"
OCPUS="${OCPUS:-4}"
MEMORY_GB="${MEMORY_GB:-16}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-120}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-}"
OWNER_TAG="${OWNER_TAG:-${USER:-unknown}}"
WORKDIR="${WORKDIR:-${HOME}/.cache/oci-poc-worker}"

usage() { sed -n '3,38p' "$0"; }
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

need_cmd oci; need_cmd jq
[[ "${OCI_COMPARTMENT_ID}" == ocid1.compartment.* ]] || { usage; die "OCI_COMPARTMENT_ID must be a compartment OCID"; }

instance_id() {
    oci compute instance list --compartment-id "${OCI_COMPARTMENT_ID}" --display-name "$1" --all 2>/dev/null \
        | jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")][0].id // empty'
}

do_launch() {
    need_cmd kubectl
    [[ $# -gt 0 ]] || die "launch needs at least one name"
    [[ "${SUBNET_ID}" == ocid1.subnet.* ]] || die "SUBNET_ID must be a subnet OCID"
    [[ "${NSG_ID}" == ocid1.networksecuritygroup.* ]] || die "NSG_ID must be an NSG OCID"
    [[ "${IMAGE_ID}" == ocid1.image.* ]] || die "IMAGE_ID must be an image OCID"
    [[ -f "${MGMT_KUBECONFIG}" ]] || die "MGMT_KUBECONFIG must point at the management cluster kubeconfig"
    local cp_ns="${NAMESPACE}-${CLUSTER_NAME}" secret ud name id ad
    secret="$(KUBECONFIG="${MGMT_KUBECONFIG}" kubectl -n "${cp_ns}" get secret -o name | grep "user-data-${NODEPOOL}-" | head -1)"
    [[ -n "${secret}" ]] || die "no user-data secret for NodePool ${NODEPOOL} in ${cp_ns}"
    mkdir -p "${WORKDIR}"; chmod 700 "${WORKDIR}"
    ud="${WORKDIR}/${NODEPOOL}.ign"
    ( umask 077; KUBECONFIG="${MGMT_KUBECONFIG}" kubectl -n "${cp_ns}" get "${secret}" -o jsonpath='{.data.value}' | base64 -d > "${ud}" )
    log "user-data from ${secret} (bearer token, kept at ${ud}, mode 0600)"
    ad="${AVAILABILITY_DOMAIN:-$(oci iam availability-domain list --compartment-id "${OCI_COMPARTMENT_ID}" --query 'data[0].name' --raw-output)}"
    for name in "$@"; do
        if id="$(instance_id "${name}")" && [[ -n "${id}" ]]; then
            log "${name} already exists, skipping"; continue
        fi
        id="$(oci compute instance launch --compartment-id "${OCI_COMPARTMENT_ID}" --availability-domain "${ad}" \
            --shape "${SHAPE}" --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}" \
            --image-id "${IMAGE_ID}" --subnet-id "${SUBNET_ID}" --assign-public-ip false \
            --nsg-ids "[\"${NSG_ID}\"]" --display-name "${name}" --hostname-label "${name}" \
            --boot-volume-size-in-gbs "${BOOT_VOLUME_GB}" --user-data-file "${ud}" \
            --instance-options '{"areLegacyImdsEndpointsDisabled": true}' \
            --freeform-tags "{\"owner\":\"${OWNER_TAG}\",\"hyperfleet-purpose\":\"oci-on-oke-poc\",\"hyperfleet-managed-by\":\"manual\",\"hosted-cluster\":\"${CLUSTER_NAME}\"}" \
            --query 'data.id' --raw-output)"
        log "launched ${name}"
    done
}

do_approve() {
    need_cmd kubectl
    [[ -f "${GUEST_KUBECONFIG}" ]] || die "GUEST_KUBECONFIG must point at the hosted cluster admin kubeconfig"
    local csr n=0
    # Client CSRs come from the node-bootstrapper service account and carry the
    # node name only in the CSR subject; serving CSRs come from system:node:<name>.
    while read -r csr; do
        [[ -z "${csr}" ]] && continue
        KUBECONFIG="${GUEST_KUBECONFIG}" kubectl certificate approve "${csr}" >/dev/null
        log "approved ${csr}"; n=$((n + 1))
    done < <(KUBECONFIG="${GUEST_KUBECONFIG}" kubectl get csr -o json | jq -r --arg p "${NAME_PREFIX}" '
        .items[] | select((.status.conditions // []) | length == 0)
        | select(.spec.signerName == "kubernetes.io/kube-apiserver-client-kubelet" or .spec.signerName == "kubernetes.io/kubelet-serving")
        | select((.spec.username | startswith("system:node:" + $p))
                 or (.spec.username == "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper"))
        | .metadata.name')
    log "${n} CSR(s) approved"
}

do_list() {
    oci compute instance list --compartment-id "${OCI_COMPARTMENT_ID}" --all 2>/dev/null \
        | jq -r --arg p "${NAME_PREFIX}" '.data[]? | select(."display-name" | startswith($p))
            | select(."lifecycle-state" != "TERMINATED") | "\(."display-name") \(."lifecycle-state") \(."fault-domain")"'
}

do_terminate() {
    [[ $# -gt 0 ]] || die "terminate needs at least one name"
    local name id
    for name in "$@"; do
        if [[ -f "${GUEST_KUBECONFIG}" ]]; then
            KUBECONFIG="${GUEST_KUBECONFIG}" kubectl delete node "${name}" --ignore-not-found >/dev/null && log "deleted Node ${name}"
        fi
        id="$(instance_id "${name}")"
        [[ -n "${id}" ]] || { log "${name} not found"; continue; }
        oci compute instance terminate --instance-id "${id}" --preserve-boot-volume false --force \
            --wait-for-state SUCCEEDED >/dev/null
        log "terminated ${name} with its boot volume"
    done
}

case "${ACTION}" in
    launch) do_launch "$@" ;;
    approve) do_approve ;;
    list) do_list ;;
    terminate) do_terminate "$@" ;;
    *) usage; exit 1 ;;
esac
