#!/usr/bin/env bash
set -euo pipefail
# One-time platform pieces on the OCI POC management cluster that let
# HyperFleet create hosted clusters with no per-cluster hand steps:
#   - an admission policy that makes every hosted cluster's router Service an
#     internal OCI load balancer and gives it the control plane hostnames
#   - external-dns (OCI provider, instance principals) for those hostnames
#   - the platform pull secret and the NodePool MachineConfig ConfigMaps in the
#     HostedCluster namespace
#
# Usage:
#   scripts/oci-poc-platform.sh <install|uninstall>
#
# Required:
#   KUBECONFIG           the OKE management cluster
#   DNS_COMPARTMENT_ID   compartment of the DNS zone (install)
#   PULL_SECRET_FILE     OpenShift pull secret (install; never committed)
# Optional:
#   BASE_DOMAIN          (default: hcp.oci.hypershell.app)
#   DNS_ZONE_FILTER      domain external-dns may touch (default: oci.hypershell.app)
#   TXT_OWNER_ID         (default: hyperfleet-poc-oke)
#   CLUSTERS_NAMESPACE   (default: clusters)
#   EXTERNAL_DNS_VERSION (default: v0.21.0; v0.22.0 generated no records from
#                        LoadBalancer Services on this cluster)

BASE_DOMAIN="${BASE_DOMAIN:-hcp.oci.hypershell.app}"
DNS_ZONE_FILTER="${DNS_ZONE_FILTER:-oci.hypershell.app}"
DNS_COMPARTMENT_ID="${DNS_COMPARTMENT_ID:-}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-}"
TXT_OWNER_ID="${TXT_OWNER_ID:-hyperfleet-poc-oke}"
CLUSTERS_NAMESPACE="${CLUSTERS_NAMESPACE:-clusters}"
EXTERNAL_DNS_VERSION="${EXTERNAL_DNS_VERSION:-v0.21.0}"
ACTION="${1:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFESTS="${REPO_ROOT}/manifests/oci-poc"

usage() { sed -n '3,26p' "$0"; }
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

do_install() {
    need_cmd kubectl; need_cmd helm
    [[ "${DNS_COMPARTMENT_ID}" == ocid1.compartment.* ]] || die "DNS_COMPARTMENT_ID must be a compartment OCID"
    [[ -f "${PULL_SECRET_FILE}" ]] || die "PULL_SECRET_FILE must point at an OpenShift pull secret"
    sed "s/BASE_DOMAIN/${BASE_DOMAIN}/" "${MANIFESTS}/hyperfleet/router-admission-policy.yaml" | kubectl apply -f -
    log "router admission policy applied for *.${BASE_DOMAIN}"
    helm upgrade --install external-dns "${REPO_ROOT}/helm/external-dns" --namespace external-dns --create-namespace \
        --set oci.compartmentId="${DNS_COMPARTMENT_ID}" --set domainFilter="${DNS_ZONE_FILTER}" \
        --set txtOwnerId="${TXT_OWNER_ID}" --set policy=sync --set image.tag="${EXTERNAL_DNS_VERSION}" --wait
    log "external-dns installed (owner ${TXT_OWNER_ID}, sync: it deletes only records it owns)"
    kubectl create namespace "${CLUSTERS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "${CLUSTERS_NAMESPACE}" create secret generic platform-pull-secret \
        --from-file=.dockerconfigjson="${PULL_SECRET_FILE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl apply -f "${MANIFESTS}/guest-oci/nodepool-config-kubelet-identity.yaml" \
        -f "${MANIFESTS}/guest-oci/nodepool-config-device-path.yaml"
    log "platform pull secret and NodePool configs in ${CLUSTERS_NAMESPACE}"
}

do_uninstall() {
    need_cmd kubectl; need_cmd helm
    helm uninstall external-dns --namespace external-dns || true
    kubectl delete -f "${MANIFESTS}/hyperfleet/router-admission-policy.yaml" --ignore-not-found
}

case "${ACTION}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    *) usage; exit 1 ;;
esac
