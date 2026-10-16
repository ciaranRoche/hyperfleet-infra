#!/usr/bin/env bash
set -euo pipefail
# Upstream HyperShift on the OCI POC OKE cluster with a platform None hosted
# cluster published privately through its per-cluster router on 443.
#
# Usage:
#   scripts/oci-poc-hypershift.sh <build|shims|install|cluster-up|router-lb|dns|status|cluster-down>
#
#   build        clone openshift/hypershift at HYPERSHIFT_COMMIT and build the CLI
#   shims        apply the CRDs a non-OpenShift management cluster lacks
#   install      render the operator install with the pinned CLI and image, apply,
#                restart the operator (management capabilities are read at startup)
#   cluster-up   namespace, pull secret and SSH key secrets, HostedCluster, NodePool
#   router-lb    make the router Service an internal OCI load balancer, wait for its IP
#   dns          upsert the four A records to the router IP (DNS_ACTION=delete removes them)
#   status       HostedCluster conditions, router IP, control plane pods
#   cluster-down delete the NodePool and HostedCluster, then the DNS records
#
# Required:
#   KUBECONFIG            the OKE management cluster
# Required for cluster-up:
#   PULL_SECRET_FILE      OpenShift pull secret (never committed)
# Optional:
#   CLUSTER_NAME          (default: demo1, must match the manifests)
#   NAMESPACE             (default: clusters)
#   BASE_DOMAIN           (default: hcp.oci.hypershell.app)
#   DNS_ZONE              (default: oci.hypershell.app)
#   DNS_COMPARTMENT_ID    compartment of DNS_ZONE (dns only)
#   SSH_PUBLIC_KEY_FILE   (default: ~/.ssh/id_ed25519.pub)
#   WORKDIR               build and render output (default: ~/.cache/oci-poc-hypershift)
#   HYPERSHIFT_COMMIT     (default: 253c3f5c790d08668d4aa365688e88a0ab950af8)
#   HYPERSHIFT_IMAGE      (default: the operator image built from that commit, by digest)

HYPERSHIFT_COMMIT="${HYPERSHIFT_COMMIT:-253c3f5c790d08668d4aa365688e88a0ab950af8}"
HYPERSHIFT_IMAGE="${HYPERSHIFT_IMAGE:-quay.io/hypershift/hypershift-operator@sha256:9a2e262ed79d57237b20a7e52813db385ea4527df1f33396da7c98d3772a0cfc}"
PROMETHEUS_OPERATOR_VERSION="v0.88.0"
OPENSHIFT_API_COMMIT="e07c1fd9d99c88fda2804b1a14bff2d14bede331"
CLUSTER_NAME="${CLUSTER_NAME:-demo1}"
NAMESPACE="${NAMESPACE:-clusters}"
BASE_DOMAIN="${BASE_DOMAIN:-hcp.oci.hypershell.app}"
DNS_ZONE="${DNS_ZONE:-oci.hypershell.app}"
DNS_COMPARTMENT_ID="${DNS_COMPARTMENT_ID:-}"
DNS_ACTION="${DNS_ACTION:-upsert}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
WORKDIR="${WORKDIR:-${HOME}/.cache/oci-poc-hypershift}"
ACTION="${1:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFESTS="${REPO_ROOT}/manifests/oci-poc/hypershift"
CLI="${WORKDIR}/hypershift/bin/hypershift"
CP_NS="${NAMESPACE}-${CLUSTER_NAME}"
HOSTS=(api oauth konnectivity ignition)

usage() { sed -n '3,36p' "$0"; }
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

wait_for() {
    local what="$1" timeout="$2"; shift 2
    local start=${SECONDS}
    until "$@" >/dev/null 2>&1; do
        (( SECONDS - start < timeout )) || die "timed out after ${timeout}s waiting for ${what}"
        sleep 5
    done
    log "${what} after $((SECONDS - start))s"
}

do_build() {
    need_cmd git; need_cmd go; need_cmd make
    mkdir -p "${WORKDIR}"
    if [[ ! -d "${WORKDIR}/hypershift/.git" ]]; then
        git init -q "${WORKDIR}/hypershift"
        git -C "${WORKDIR}/hypershift" remote add origin https://github.com/openshift/hypershift.git
    fi
    git -C "${WORKDIR}/hypershift" fetch -q --depth 1 origin "${HYPERSHIFT_COMMIT}"
    git -C "${WORKDIR}/hypershift" checkout -q FETCH_HEAD
    make -C "${WORKDIR}/hypershift" hypershift
    "${CLI}" version 2>/dev/null | head -1 || true
}

do_shims() {
    need_cmd kubectl
    local base="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROMETHEUS_OPERATOR_VERSION}/example/prometheus-operator-crd"
    # The HostedCluster controller watches PodMonitor unconditionally and the
    # install renders a ServiceMonitor and a PrometheusRule even with
    # --platform-monitoring None.
    kubectl apply --server-side \
        -f "${base}/monitoring.coreos.com_servicemonitors.yaml" \
        -f "${base}/monitoring.coreos.com_podmonitors.yaml" \
        -f "${base}/monitoring.coreos.com_prometheusrules.yaml"
    # Route publishing is rejected without the Route API, and the None CLI
    # publishes three of four services as Routes by default.
    kubectl apply --server-side \
        -f "https://raw.githubusercontent.com/openshift/api/${OPENSHIFT_API_COMMIT}/route/v1/zz_generated.crd-manifests/routes.crd.yaml"
    kubectl wait --for=condition=Established --timeout=60s \
        crd/servicemonitors.monitoring.coreos.com crd/podmonitors.monitoring.coreos.com \
        crd/prometheusrules.monitoring.coreos.com crd/routes.route.openshift.io
}

do_install() {
    need_cmd kubectl
    [[ -x "${CLI}" ]] || die "CLI not built, run: $0 build"
    "${CLI}" install render --hypershift-image "${HYPERSHIFT_IMAGE}" --platform-monitoring None \
        --format yaml > "${WORKDIR}/install.yaml"
    log "rendered $(grep -c '^kind:' "${WORKDIR}/install.yaml") objects to ${WORKDIR}/install.yaml"
    kubectl apply --server-side -f "${WORKDIR}/install.yaml" >/dev/null
    # Capabilities such as the Route API are detected only when the operator starts.
    kubectl -n hypershift rollout restart deploy/operator
    kubectl -n hypershift rollout status deploy/operator --timeout=300s
}

do_cluster_up() {
    need_cmd kubectl
    [[ -f "${PULL_SECRET_FILE}" ]] || die "PULL_SECRET_FILE must point at an OpenShift pull secret"
    [[ -f "${SSH_PUBLIC_KEY_FILE}" ]] || die "SSH_PUBLIC_KEY_FILE not found"
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "${NAMESPACE}" create secret generic "${CLUSTER_NAME}-pull-secret" \
        --from-file=.dockerconfigjson="${PULL_SECRET_FILE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "${NAMESPACE}" create secret generic "${CLUSTER_NAME}-ssh-key" \
        --from-file=id_rsa.pub="${SSH_PUBLIC_KEY_FILE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    if ! kubectl -n "${NAMESPACE}" get secret "${CLUSTER_NAME}-etcd-encryption-key" >/dev/null 2>&1; then
        kubectl -n "${NAMESPACE}" create secret generic "${CLUSTER_NAME}-etcd-encryption-key" \
            --from-literal=key="$(head -c 32 /dev/urandom | base64)" >/dev/null
    fi
    kubectl apply -f "${MANIFESTS}/hostedcluster-${CLUSTER_NAME}.yaml" -f "${MANIFESTS}/nodepool-${CLUSTER_NAME}.yaml"
    wait_for "router Service" 900 kubectl -n "${CP_NS}" get svc router
    do_router_lb
    wait_for "KubeAPIServerAvailable" 1200 \
        bash -c "[[ \"\$(kubectl -n ${NAMESPACE} get hostedcluster ${CLUSTER_NAME} -o jsonpath='{.status.conditions[?(@.type==\"KubeAPIServerAvailable\")].status}')\" == True ]]"
}

router_ip() { kubectl -n "${CP_NS}" get svc router -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }

do_router_lb() {
    need_cmd kubectl
    kubectl -n "${CP_NS}" patch svc router --type merge --patch-file "${MANIFESTS}/router-internal-lb.yaml" >/dev/null
    wait_for "router private IP" 300 bash -c "[[ -n \"\$(kubectl -n ${CP_NS} get svc router -o jsonpath='{.status.loadBalancer.ingress[0].ip}')\" ]]"
    log "router IP $(router_ip)"
}

do_dns() {
    need_cmd oci
    [[ "${DNS_COMPARTMENT_ID}" == ocid1.compartment.* ]] || die "DNS_COMPARTMENT_ID must be the zone's compartment OCID"
    local ip="" h d
    if [[ "${DNS_ACTION}" == "upsert" ]]; then
        ip="$(router_ip)"; [[ -n "${ip}" ]] || die "router has no IP yet"
    fi
    for h in "${HOSTS[@]}"; do
        d="${h}.${CLUSTER_NAME}.${BASE_DOMAIN}"
        if [[ "${DNS_ACTION}" == "delete" ]]; then
            oci dns record rrset delete --zone-name-or-id "${DNS_ZONE}" --compartment-id "${DNS_COMPARTMENT_ID}" \
                --domain "${d}" --rtype A --force >/dev/null
            log "deleted ${d}"
        else
            oci dns record rrset update --zone-name-or-id "${DNS_ZONE}" --compartment-id "${DNS_COMPARTMENT_ID}" \
                --domain "${d}" --rtype A --force \
                --items "[{\"domain\":\"${d}\",\"rtype\":\"A\",\"rdata\":\"${ip}\",\"ttl\":60}]" >/dev/null
            log "${d} -> ${ip}"
        fi
    done
}

do_status() {
    need_cmd kubectl; need_cmd jq
    kubectl -n "${NAMESPACE}" get hostedcluster "${CLUSTER_NAME}" -o json | jq -r '.status.conditions[]
        | select(.type|test("^(Available|EtcdAvailable|KubeAPIServerAvailable|IgnitionEndpointAvailable|ValidConfiguration)$"))
        | "\(.type)=\(.status) \(.reason)"'
    echo "router IP: $(router_ip 2>/dev/null || echo none)"
    kubectl -n "${CP_NS}" get pods --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c
}

do_cluster_down() {
    need_cmd kubectl
    kubectl -n "${NAMESPACE}" delete nodepool --all --wait=true --timeout=300s
    kubectl -n "${NAMESPACE}" delete hostedcluster "${CLUSTER_NAME}" --wait=true --timeout=900s
    if [[ -n "${DNS_COMPARTMENT_ID}" ]]; then DNS_ACTION=delete do_dns; else log "DNS_COMPARTMENT_ID unset, DNS records left in place"; fi
}

case "${ACTION}" in
    build) do_build ;;
    shims) do_shims ;;
    install) do_install ;;
    cluster-up) do_cluster_up ;;
    router-lb) do_router_lb ;;
    dns) do_dns ;;
    status) do_status ;;
    cluster-down) do_cluster_down ;;
    *) usage; exit 1 ;;
esac
