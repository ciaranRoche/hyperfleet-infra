#!/usr/bin/env bash
set -euo pipefail
# Sweep what Terraform does not own in the OCI POC compartment tree before and
# after `terraform destroy`: load balancers and network load balancers created
# by a cloud controller manager, the NSGs it creates for them, unattached
# block and boot volumes (OKE leaves node boot volumes behind), and console
# history captures (they block compartment deletion). Lists compute instances
# and buckets with objects but only deletes instances when asked. Never
# touches custom images or anything tagged hyperfleet-keep=true.
#
# Usage:
#   scripts/oci-poc-sweep.sh <list|sweep>
#
# Required:
#   OCI_COMPARTMENT_ID   root of the tree to sweep (the hyperfleet-poc compartment)
# Optional:
#   DRY_RUN              true prints what sweep would delete (default: true)
#   SWEEP_INSTANCES      true also terminates compute instances with their boot
#                        volumes; OKE node pool instances are skipped (default: false)
#   OCI_CLI_PROFILE, OCI_CLI_AUTH are passed through to the oci CLI.

OCI_COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"
DRY_RUN="${DRY_RUN:-true}"
SWEEP_INSTANCES="${SWEEP_INSTANCES:-false}"
ACTION="${1:-list}"

usage() { sed -n '3,20p' "$0"; }
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

# The OCI CLI prints usage errors on stdout; capture and show them on failure.
quiet() {
    local out
    if ! out="$("$@" 2>&1)"; then
        echo "$out" >&2
        return 1
    fi
}

[[ "${ACTION}" == "list" || "${ACTION}" == "sweep" ]] || { usage; die "action must be list or sweep"; }
[[ "${OCI_COMPARTMENT_ID}" == ocid1.compartment.* ]] || die "OCI_COMPARTMENT_ID must be a compartment OCID"
[[ "${DRY_RUN}" == "true" || "${DRY_RUN}" == "false" ]] || die "DRY_RUN must be true or false"
need_cmd oci
need_cmd jq

# `oci ... list` prints nothing for an empty result, so default to []. Most
# list commands return `data` as an array; the network load balancer service
# wraps it as `data.items`.
list_json() {
    local out
    out="$(oci "$@" --all 2>/dev/null || true)"
    jq -c '.data // [] | if type == "object" then (.items // []) else . end' <<<"${out:-{\}}"
}

keep_tagged() { jq -e '(."freeform-tags"["hyperfleet-keep"] // "") == "true"' <<<"$1" >/dev/null; }
tf_tagged() { jq -e '(."freeform-tags"["hyperfleet-managed-by"] // "") == "terraform"' <<<"$1" >/dev/null; }

deleting() {
    if [[ "${ACTION}" == "sweep" && "${DRY_RUN}" == "false" ]]; then
        log "  deleting $1"
        return 0
    fi
    log "  would delete $1"
    return 1
}

# Walk the tree one level at a time; `--compartment-id-in-subtree` only works
# from the tenancy root.
compartments() {
    local parent="$1" child
    echo "${parent}"
    while read -r child; do
        [[ -z "${child}" ]] && continue
        compartments "${child}"
    done < <(list_json iam compartment list --compartment-id "${parent}" --lifecycle-state ACTIVE | jq -r '.[].id')
}

ad="$(oci iam availability-domain list --compartment-id "${OCI_COMPARTMENT_ID}" --query 'data[0].name' --raw-output)"
found=0

sweep_load_balancers() {
    local c="$1" item name id
    while read -r item; do
        [[ -z "${item}" ]] && continue
        name="$(jq -r '."display-name"' <<<"${item}")"; id="$(jq -r '.id' <<<"${item}")"
        found=$((found + 1))
        if keep_tagged "${item}"; then log "  keep (hyperfleet-keep): load balancer ${name}"; continue; fi
        if deleting "load balancer ${name}"; then quiet oci lb load-balancer delete --load-balancer-id "${id}" --force --wait-for-state SUCCEEDED; fi
    done < <(list_json lb load-balancer list --compartment-id "${c}" | jq -c '.[] | select(."lifecycle-state" != "DELETING" and ."lifecycle-state" != "DELETED")')
    while read -r item; do
        [[ -z "${item}" ]] && continue
        name="$(jq -r '."display-name"' <<<"${item}")"; id="$(jq -r '.id' <<<"${item}")"
        found=$((found + 1))
        if keep_tagged "${item}"; then log "  keep (hyperfleet-keep): network load balancer ${name}"; continue; fi
        if deleting "network load balancer ${name}"; then quiet oci nlb network-load-balancer delete --network-load-balancer-id "${id}" --force --wait-for-state SUCCEEDED; fi
    done < <(list_json nlb network-load-balancer list --compartment-id "${c}" | jq -c '.[] | select(."lifecycle-state" != "DELETING" and ."lifecycle-state" != "DELETED")')
}

sweep_instances() {
    local c="$1" item name id
    while read -r item; do
        [[ -z "${item}" ]] && continue
        name="$(jq -r '."display-name"' <<<"${item}")"; id="$(jq -r '.id' <<<"${item}")"
        found=$((found + 1))
        if keep_tagged "${item}"; then log "  keep (hyperfleet-keep): instance ${name}"; continue; fi
        if jq -e '."metadata"["oke-cluster-id"] // ."defined-tags"["oke-cluster-id"] // empty' <<<"${item}" >/dev/null 2>&1 \
            || [[ "${name}" == oke-* ]]; then
            log "  skip (OKE node): instance ${name}"; continue
        fi
        if [[ "${SWEEP_INSTANCES}" != "true" ]]; then log "  listed only (SWEEP_INSTANCES=false): instance ${name}"; continue; fi
        if deleting "instance ${name} with its boot volume"; then quiet oci compute instance terminate --instance-id "${id}" --preserve-boot-volume false --force --wait-for-state SUCCEEDED; fi
    done < <(list_json compute instance list --compartment-id "${c}" | jq -c '.[] | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")')
}

sweep_nsgs() {
    local c="$1" item name id
    while read -r item; do
        [[ -z "${item}" ]] && continue
        name="$(jq -r '."display-name"' <<<"${item}")"; id="$(jq -r '.id' <<<"${item}")"
        if tf_tagged "${item}"; then continue; fi
        found=$((found + 1))
        if keep_tagged "${item}"; then log "  keep (hyperfleet-keep): NSG ${name}"; continue; fi
        if deleting "NSG ${name} (not Terraform-managed)"; then quiet oci network nsg delete --nsg-id "${id}" --force --wait-for-state TERMINATED; fi
    done < <(list_json network nsg list --compartment-id "${c}" | jq -c '.[] | select(."lifecycle-state" == "AVAILABLE")')
}

sweep_volumes() {
    local c="$1" item name id
    while read -r item; do
        [[ -z "${item}" ]] && continue
        name="$(jq -r '."display-name"' <<<"${item}")"; id="$(jq -r '.id' <<<"${item}")"
        found=$((found + 1))
        if keep_tagged "${item}"; then log "  keep (hyperfleet-keep): block volume ${name}"; continue; fi
        if [[ "$(list_json compute volume-attachment list --compartment-id "${c}" --volume-id "${id}" | jq '[.[] | select(."lifecycle-state" == "ATTACHED")] | length')" != "0" ]]; then
            log "  skip (attached): block volume ${name}"; continue
        fi
        if deleting "block volume ${name}"; then quiet oci bv volume delete --volume-id "${id}" --force --wait-for-state TERMINATED; fi
    done < <(list_json bv volume list --compartment-id "${c}" | jq -c '.[] | select(."lifecycle-state" == "AVAILABLE")')
    while read -r item; do
        [[ -z "${item}" ]] && continue
        name="$(jq -r '."display-name"' <<<"${item}")"; id="$(jq -r '.id' <<<"${item}")"
        if [[ "$(list_json compute boot-volume-attachment list --compartment-id "${c}" --availability-domain "${ad}" --boot-volume-id "${id}" | jq '[.[] | select(."lifecycle-state" == "ATTACHED")] | length')" != "0" ]]; then
            continue
        fi
        found=$((found + 1))
        if keep_tagged "${item}"; then log "  keep (hyperfleet-keep): boot volume ${name}"; continue; fi
        if deleting "unattached boot volume ${name}"; then quiet oci bv boot-volume delete --boot-volume-id "${id}" --force --wait-for-state TERMINATED; fi
    done < <(list_json bv boot-volume list --compartment-id "${c}" --availability-domain "${ad}" | jq -c '.[] | select(."lifecycle-state" == "AVAILABLE")')
}

sweep_console_histories() {
    local c="$1" item name id
    while read -r item; do
        [[ -z "${item}" ]] && continue
        name="$(jq -r '."display-name"' <<<"${item}")"; id="$(jq -r '.id' <<<"${item}")"
        found=$((found + 1))
        if deleting "console history ${name}"; then quiet oci compute console-history delete --instance-console-history-id "${id}" --force; fi
    done < <(list_json compute console-history list --compartment-id "${c}" | jq -c '.[]')
}

list_buckets() {
    local c="$1" ns name n
    ns="$(oci os ns get --query data --raw-output)"
    while read -r name; do
        [[ -z "${name}" ]] && continue
        n="$(list_json os object list --namespace-name "${ns}" --bucket-name "${name}" | jq 'length')"
        log "  listed only: bucket ${name} with ${n} object(s)"
    done < <(list_json os bucket list --namespace-name "${ns}" --compartment-id "${c}" | jq -r '.[].name')
}

echo "=== OCI POC sweep (${ACTION}, dry run ${DRY_RUN}) ==="
echo "Root compartment: ${OCI_COMPARTMENT_ID}"
echo ""

while read -r c; do
    [[ -z "${c}" ]] && continue
    cname="$(oci iam compartment get --compartment-id "${c}" --query 'data.name' --raw-output)"
    log "compartment ${cname}"
    sweep_load_balancers "${c}"
    sweep_instances "${c}"
    sweep_nsgs "${c}"
    sweep_volumes "${c}"
    sweep_console_histories "${c}"
    list_buckets "${c}"
done < <(compartments "${OCI_COMPARTMENT_ID}")

echo ""
if [[ "${found}" == "0" ]]; then
    log "nothing outside Terraform's ownership found"
else
    log "${found} item(s) found; see above for what was deleted, kept or only listed"
fi
