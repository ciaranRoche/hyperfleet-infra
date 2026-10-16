#!/usr/bin/env bash
set -euo pipefail
# Oracle's cloud controller manager and block volume CSI driver as day-2
# manifests in a platform None hosted cluster whose workers run in a customer
# compartment. The upstream release manifests assume control-plane nodes and
# kube-system; a hosted cluster's guest has only workers, so this re-targets
# them to worker nodes in dedicated namespaces, the way Oracle's standalone
# OpenShift stack isolates them.
#
# Usage:
#   scripts/oci-poc-guest-oci.sh <render|install|uninstall>
#
#   render     fetch the pinned release manifests and write the re-targeted
#              provider package plus config secrets to OUTDIR
#   install    render, then apply to the guest and make oci-bv the default class
#   configure  day-2 guest settings OCI needs: OVN masquerade subnet clear of the
#              iSCSI targets, default ingress on an internal OCI load balancer,
#              image registry on a block volume
#   uninstall  delete what install applied (LoadBalancer Services and PVCs first!)
#
# Required:
#   GUEST_KUBECONFIG     hosted cluster admin kubeconfig (install, uninstall)
#   COMPARTMENT_ID       customer compartment the workers run in
#   VCN_ID               customer VCN
#   LB_SUBNET_ID         default subnet for load balancers (the customer's private LB subnet)
# Optional:
#   CCM_VERSION          oracle/oci-cloud-controller-manager release (default: v1.35.1)
#   OUTDIR               (default: ~/.cache/oci-poc-guest-oci)
#   CLUSTER_TAG          value of the hyperfleet-cluster freeform tag the CCM and CSI
#                        put on every load balancer, NSG and volume they create, so
#                        they can be found and removed after the cluster is gone

CCM_VERSION="${CCM_VERSION:-v1.35.1}"
COMPARTMENT_ID="${COMPARTMENT_ID:-}"
VCN_ID="${VCN_ID:-}"
LB_SUBNET_ID="${LB_SUBNET_ID:-}"
GUEST_KUBECONFIG="${GUEST_KUBECONFIG:-}"
OUTDIR="${OUTDIR:-${HOME}/.cache/oci-poc-guest-oci}"
CLUSTER_TAG="${CLUSTER_TAG:-}"
ACTION="${1:-}"

MANIFESTS="$(cd "$(dirname "$0")/.." && pwd)/manifests/oci-poc/guest-oci"
CCM_NS="oci-cloud-controller-manager"
CSI_NS="oci-csi"
RELEASE_URL="https://github.com/oracle/oci-cloud-controller-manager/releases/download/${CCM_VERSION}"

usage() { sed -n '3,32p' "$0"; }
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

namespace() {
    # Privileged PodSecurity and OpenShift run-level 0 exempt the namespace from
    # SCC admission, as Oracle's standalone OpenShift manifests do: both
    # components need host networking and host mounts.
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $1
  annotations:
    workload.openshift.io/allowed: management
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
    openshift.io/run-level: "0"
EOF
}

provider_config() {
    # securityListManagementMode None: the CCM never edits security lists.
    # Services opt into a CCM-owned NSG per load balancer with the
    # oci.oraclecloud.com/security-rule-management-mode: NSG annotation.
    cat <<EOF
useInstancePrincipals: true
compartment: ${COMPARTMENT_ID}
vcn: ${VCN_ID}
loadBalancer:
  subnet1: ${LB_SUBNET_ID}
  securityListManagementMode: None
rateLimiter:
  rateLimitQPSRead: 20.0
  rateLimitBucketRead: 5
  rateLimitQPSWrite: 20.0
  rateLimitBucketWrite: 5
EOF
    if [[ -n "${CLUSTER_TAG}" ]]; then
        cat <<EOF
tags:
  common:
    freeform:
      hyperfleet-cluster: ${CLUSTER_TAG}
EOF
    fi
}

retarget() {
    # $1 file, $2 namespace: move namespaced objects and RBAC subjects out of
    # kube-system, and schedule control-plane workloads on workers instead.
    yq eval-all "
        (select(.metadata.namespace == \"kube-system\") | .metadata.namespace) = \"$2\" |
        (select(.kind == \"ClusterRoleBinding\" or .kind == \"RoleBinding\") | .subjects[] | select(.namespace == \"kube-system\") | .namespace) = \"$2\" |
        (select(.spec.template.spec.nodeSelector.\"node-role.kubernetes.io/control-plane\" != null) | .spec.template.spec.nodeSelector) = {\"node-role.kubernetes.io/worker\": \"\"}
    " "$1"
}

do_render() {
    need_cmd curl; need_cmd yq
    [[ "${COMPARTMENT_ID}" == ocid1.compartment.* ]] || die "COMPARTMENT_ID must be a compartment OCID"
    [[ "${VCN_ID}" == ocid1.vcn.* ]] || die "VCN_ID must be a VCN OCID"
    [[ "${LB_SUBNET_ID}" == ocid1.subnet.* ]] || die "LB_SUBNET_ID must be a subnet OCID"
    local src="${OUTDIR}/upstream-${CCM_VERSION}" f
    mkdir -p "${src}" "${OUTDIR}/package"
    for f in oci-cloud-controller-manager-rbac.yaml oci-cloud-controller-manager.yaml \
             oci-csi-node-rbac.yaml oci-csi-controller-driver.yaml oci-csi-node-driver.yaml storage-class.yaml; do
        [[ -s "${src}/${f}" ]] || curl -sfL -o "${src}/${f}" "${RELEASE_URL}/${f}"
    done
    {
        namespace "${CCM_NS}"; echo "---"
        retarget "${src}/oci-cloud-controller-manager-rbac.yaml" "${CCM_NS}"; echo "---"
        retarget "${src}/oci-cloud-controller-manager.yaml" "${CCM_NS}"
    } > "${OUTDIR}/package/10-ccm.yaml"
    {
        namespace "${CSI_NS}"; echo "---"
        retarget "${src}/oci-csi-node-rbac.yaml" "${CSI_NS}"; echo "---"
        retarget "${src}/oci-csi-controller-driver.yaml" "${CSI_NS}"; echo "---"
        retarget "${src}/oci-csi-node-driver.yaml" "${CSI_NS}"
    } > "${OUTDIR}/package/20-csi.yaml"
    # Block volume class only: the flexvolume "oci" class and lustre need drivers
    # this package does not install.
    yq eval-all 'select(.metadata.name == "oci-bv")' "${src}/storage-class.yaml" > "${OUTDIR}/package/30-storage-class.yaml"
    ( umask 077
      kubectl create secret generic oci-cloud-controller-manager -n "${CCM_NS}" \
          --from-file=cloud-provider.yaml=<(provider_config) --dry-run=client -o yaml > "${OUTDIR}/package/05-ccm-config.yaml"
      kubectl create secret generic oci-volume-provisioner -n "${CSI_NS}" \
          --from-file=config.yaml=<(provider_config) --dry-run=client -o yaml > "${OUTDIR}/package/05-csi-config.yaml" )
    log "rendered ${CCM_VERSION} provider package to ${OUTDIR}/package"
    grep -h "image:" "${OUTDIR}"/package/*.yaml | sort | uniq -c
}

guest() { KUBECONFIG="${GUEST_KUBECONFIG}" kubectl "$@"; }

do_install() {
    need_cmd kubectl
    [[ -f "${GUEST_KUBECONFIG}" ]] || die "GUEST_KUBECONFIG must point at the hosted cluster admin kubeconfig"
    do_render
    guest apply -f <(namespace "${CCM_NS}") -f <(namespace "${CSI_NS}")
    guest apply -f "${OUTDIR}/package/05-ccm-config.yaml" -f "${OUTDIR}/package/05-csi-config.yaml"
    guest apply -f "${OUTDIR}/package/10-ccm.yaml" -f "${OUTDIR}/package/20-csi.yaml" -f "${OUTDIR}/package/30-storage-class.yaml"
    guest annotate storageclass oci-bv storageclass.kubernetes.io/is-default-class=true --overwrite
    guest -n "${CCM_NS}" rollout status ds/oci-cloud-controller-manager --timeout=300s
    guest -n "${CSI_NS}" rollout status deploy/csi-oci-controller --timeout=300s
    guest -n "${CSI_NS}" rollout status ds/csi-oci-node --timeout=300s
}

do_configure() {
    need_cmd kubectl
    [[ -f "${GUEST_KUBECONFIG}" ]] || die "GUEST_KUBECONFIG must point at the hosted cluster admin kubeconfig"
    guest patch network.operator cluster --type merge --patch-file "${MANIFESTS}/guest-network-masquerade.yaml"
    # The default IngressController must already be LoadBalancerService, set at
    # creation through the HostedCluster's operatorConfiguration.ingressOperator.
    local strategy
    strategy="$(guest -n openshift-ingress-operator get ingresscontroller default -o jsonpath='{.status.endpointPublishingStrategy.type}')"
    if [[ "${strategy}" == "LoadBalancerService" ]]; then
        guest -n openshift-ingress patch svc router-default --type merge --patch-file "${MANIFESTS}/router-default-internal-lb.yaml"
        log "router-default annotated as an internal OCI load balancer"
    else
        log "default ingress publishes as ${strategy}; set the HostedCluster ingress strategy and recreate it first"
    fi
    guest apply -f "${MANIFESTS}/registry-pvc.yaml"
    guest patch config.imageregistry cluster --type merge \
        -p '{"spec":{"storage":{"emptyDir":null,"pvc":{"claim":"image-registry-storage-rwo"}},"rolloutStrategy":"Recreate","replicas":1}}'
}

do_uninstall() {
    need_cmd kubectl
    [[ -f "${GUEST_KUBECONFIG}" ]] || die "GUEST_KUBECONFIG must point at the hosted cluster admin kubeconfig"
    [[ -d "${OUTDIR}/package" ]] || die "nothing rendered in ${OUTDIR}/package"
    guest delete --ignore-not-found -f "${OUTDIR}/package/30-storage-class.yaml" \
        -f "${OUTDIR}/package/20-csi.yaml" -f "${OUTDIR}/package/10-ccm.yaml"
}

case "${ACTION}" in
    render) do_render ;;
    install) do_install ;;
    configure) do_configure ;;
    uninstall) do_uninstall ;;
    *) usage; exit 1 ;;
esac
