#!/usr/bin/env bash
set -euo pipefail

# Launch an RHCOS test instance on OCI from a custom image, with an Ignition
# config passed as instance user data, and collect the evidence that Ignition
# ran from the metadata service. Creates its own throwaway VCN so it does not
# depend on any other environment, and removes everything on `down`.
#
# Usage:
#   scripts/oci-rhcos-test-instance.sh <up|wait|collect|down|status>
#
# `wait` resumes `up` for an instance that already exists (timings count from
# its creation time).
#
# Required:
#   OCI_COMPARTMENT_ID     compartment for the network and the instance
#   IMAGE_ID               custom image OCID (up only)
# Optional:
#   INSTANCE_NAME          (default: rhcos-image-test-1)
#   NETWORK_NAME           VCN, subnet and NSG display name (default: rhcos-image-test)
#   VCN_CIDR               (default: 10.90.0.0/24)
#   ALLOW_CIDR             source CIDR allowed on TCP 22 (default: this host's public IP /32)
#   SSH_PUBLIC_KEY_FILE    (default: ~/.ssh/id_ed25519.pub)
#   SSH_PRIVATE_KEY_FILE   (default: SSH_PUBLIC_KEY_FILE without .pub)
#   CORE_PASSWORD_HASH     optional crypt hash for the core user, for the serial console
#   SHAPE                  (default: VM.Standard.E5.Flex)
#   OCPUS, MEMORY_GB       (default: 2, 8)
#   BOOT_VOLUME_GB         (default: 100)
#   LEGACY_IMDS_DISABLED   true to launch with the legacy IMDS v1 endpoints disabled (default: false)
#   MARKER                 text written to /etc/rhcos-oci-marker (default: instance name and time)
#   OUTDIR                 where evidence is written (default: ./rhcos-oci-evidence/<instance>-<timestamp>)
#   SSH_WAIT_SECONDS       how long `up` waits for SSH (default: 900)
#   KEEP_NETWORK           true to keep the VCN on `down` (default: false)
#   OWNER_TAG, PURPOSE_TAG freeform tag values (default: $USER, oci-on-oke-poc)

OCI_COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"
IMAGE_ID="${IMAGE_ID:-}"
INSTANCE_NAME="${INSTANCE_NAME:-rhcos-image-test-1}"
NETWORK_NAME="${NETWORK_NAME:-rhcos-image-test}"
VCN_CIDR="${VCN_CIDR:-10.90.0.0/24}"
ALLOW_CIDR="${ALLOW_CIDR:-}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-${SSH_PUBLIC_KEY_FILE%.pub}}"
CORE_PASSWORD_HASH="${CORE_PASSWORD_HASH:-}"
SHAPE="${SHAPE:-VM.Standard.E5.Flex}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-8}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-100}"
LEGACY_IMDS_DISABLED="${LEGACY_IMDS_DISABLED:-false}"
MARKER="${MARKER:-${INSTANCE_NAME} $(date -u +%Y-%m-%dT%H:%M:%SZ)}"
OUTDIR="${OUTDIR:-}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-900}"
KEEP_NETWORK="${KEEP_NETWORK:-false}"
OWNER_TAG="${OWNER_TAG:-${USER:-unknown}}"
PURPOSE_TAG="${PURPOSE_TAG:-oci-on-oke-poc}"
TAGS="{\"owner\":\"${OWNER_TAG}\",\"purpose\":\"${PURPOSE_TAG}\"}"

usage() {
    sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date -u +%H:%M:%S)] $*"
}

# The OCI CLI prints usage errors on stdout, so a bare >/dev/null hides them.
# Run a command silently and show its output only when it fails.
quiet() {
    local out
    if ! out="$("$@" 2>&1)"; then
        echo "${out}" >&2
        die "command failed: $1 $2 $3"
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

for c in oci jq curl ssh; do need_cmd "$c"; done

ACTION="${1:-}"
case "${ACTION}" in
    up|wait|collect|down|status) ;;
    *) usage ;;
esac

[[ -n "${OCI_COMPARTMENT_ID}" ]] || die "OCI_COMPARTMENT_ID is required"
[[ "${OCI_COMPARTMENT_ID}" == ocid1.compartment.* ]] || die "OCI_COMPARTMENT_ID does not look like a compartment OCID"
[[ "${LEGACY_IMDS_DISABLED}" == "true" || "${LEGACY_IMDS_DISABLED}" == "false" ]] || die "LEGACY_IMDS_DISABLED must be true or false"

SSH_OPTS=(-i "${SSH_PRIVATE_KEY_FILE}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR)

# `oci ... list` prints nothing for an empty result, so every lookup goes
# through jq with a default.
first_id() {
    jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")][0].id // empty' 2>/dev/null || true
}

find_vcn() {
    oci network vcn list --compartment-id "${OCI_COMPARTMENT_ID}" --display-name "${NETWORK_NAME}" --all 2>/dev/null | first_id
}

find_subnet() {
    oci network subnet list --compartment-id "${OCI_COMPARTMENT_ID}" --vcn-id "$1" --display-name "${NETWORK_NAME}" --all 2>/dev/null | first_id
}

find_nsg() {
    oci network nsg list --compartment-id "${OCI_COMPARTMENT_ID}" --vcn-id "$1" --display-name "${NETWORK_NAME}" --all 2>/dev/null | first_id
}

find_igw() {
    oci network internet-gateway list --compartment-id "${OCI_COMPARTMENT_ID}" --vcn-id "$1" --display-name "${NETWORK_NAME}" --all 2>/dev/null | first_id
}

find_instance() {
    oci compute instance list --compartment-id "${OCI_COMPARTMENT_ID}" --display-name "${INSTANCE_NAME}" --all 2>/dev/null | first_id
}

instance_public_ip() {
    oci compute instance list-vnics --instance-id "$1" 2>/dev/null | jq -r '.data[0]."public-ip" // empty'
}

ensure_network() {
    local vcn subnet nsg igw rt sl
    vcn="$(find_vcn)"
    if [[ -z "${vcn}" ]]; then
        log "network: creating VCN ${NETWORK_NAME} ${VCN_CIDR}"
        vcn="$(oci network vcn create --compartment-id "${OCI_COMPARTMENT_ID}" --cidr-block "${VCN_CIDR}" \
            --display-name "${NETWORK_NAME}" --dns-label rhcostest --freeform-tags "${TAGS}" \
            --wait-for-state AVAILABLE --query data.id --raw-output)"
    else
        log "network: VCN ${NETWORK_NAME} exists"
    fi

    igw="$(find_igw "${vcn}")"
    if [[ -z "${igw}" ]]; then
        log "network: creating internet gateway"
        igw="$(oci network internet-gateway create --compartment-id "${OCI_COMPARTMENT_ID}" --vcn-id "${vcn}" \
            --is-enabled true --display-name "${NETWORK_NAME}" --freeform-tags "${TAGS}" \
            --wait-for-state AVAILABLE --query data.id --raw-output)"
    fi

    rt="$(oci network vcn get --vcn-id "${vcn}" --query 'data."default-route-table-id"' --raw-output)"
    quiet oci network route-table update --rt-id "${rt}" --force \
        --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${igw}\"}]"

    # The default security list opens TCP 22 to the world. Strip it to egress
    # only so the NSG below is the only thing that admits traffic.
    sl="$(oci network vcn get --vcn-id "${vcn}" --query 'data."default-security-list-id"' --raw-output)"
    quiet oci network security-list update --security-list-id "${sl}" --force \
        --ingress-security-rules '[]' \
        --egress-security-rules '[{"destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","protocol":"all"}]'

    subnet="$(find_subnet "${vcn}")"
    if [[ -z "${subnet}" ]]; then
        log "network: creating public subnet"
        subnet="$(oci network subnet create --compartment-id "${OCI_COMPARTMENT_ID}" --vcn-id "${vcn}" \
            --cidr-block "${VCN_CIDR}" --display-name "${NETWORK_NAME}" --dns-label pub \
            --prohibit-public-ip-on-vnic false --freeform-tags "${TAGS}" \
            --wait-for-state AVAILABLE --query data.id --raw-output)"
    fi

    nsg="$(find_nsg "${vcn}")"
    if [[ -z "${nsg}" ]]; then
        log "network: creating NSG, TCP 22 from ${ALLOW_CIDR}"
        nsg="$(oci network nsg create --compartment-id "${OCI_COMPARTMENT_ID}" --vcn-id "${vcn}" \
            --display-name "${NETWORK_NAME}" --freeform-tags "${TAGS}" \
            --wait-for-state AVAILABLE --query data.id --raw-output)"
        quiet oci network nsg rules add --nsg-id "${nsg}" --security-rules "[
            {\"direction\":\"INGRESS\",\"protocol\":\"6\",\"source\":\"${ALLOW_CIDR}\",\"sourceType\":\"CIDR_BLOCK\",
             \"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}},\"description\":\"ssh from the operator\"},
            {\"direction\":\"EGRESS\",\"protocol\":\"all\",\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\"}
        ]"
    fi

    SUBNET_ID="${subnet}"
    NSG_ID="${nsg}"
}

write_ignition() {
    local key hostname_src marker_src users
    key="$(cat "${SSH_PUBLIC_KEY_FILE}")"
    hostname_src="data:,$(jq -rn --arg v "${INSTANCE_NAME}" '$v|@uri')"
    marker_src="data:,$(jq -rn --arg v "${MARKER}" '$v|@uri')"
    users="$(jq -nc --arg key "${key}" --arg hash "${CORE_PASSWORD_HASH}" \
        '[{name: "core", sshAuthorizedKeys: [$key]} + (if $hash != "" then {passwordHash: $hash} else {} end)]')"
    jq -n --argjson users "${users}" --arg hostname "${hostname_src}" --arg marker "${marker_src}" '{
        ignition: {version: "3.4.0"},
        passwd: {users: $users},
        storage: {files: [
            {path: "/etc/hostname", mode: 420, overwrite: true, contents: {source: $hostname}},
            {path: "/etc/rhcos-oci-marker", mode: 420, contents: {source: $marker}}
        ]}
    }' > "${OUTDIR}/test.ign"
    log "ignition: wrote ${OUTDIR}/test.ign"
}

do_up() {
    [[ -n "${IMAGE_ID}" ]] || die "IMAGE_ID is required for up"
    [[ -f "${SSH_PUBLIC_KEY_FILE}" ]] || die "SSH public key not found: ${SSH_PUBLIC_KEY_FILE}"
    if [[ -z "${ALLOW_CIDR}" ]]; then
        ALLOW_CIDR="$(curl -fsS -4 https://ifconfig.me)/32" || die "could not detect the public IP, set ALLOW_CIDR"
    fi
    mkdir -p "${OUTDIR}"

    local existing
    existing="$(find_instance)"
    [[ -z "${existing}" ]] || die "instance ${INSTANCE_NAME} already exists (${existing}), run down first or pick another INSTANCE_NAME"

    echo "=== RHCOS test instance ==="
    echo "Instance:     ${INSTANCE_NAME}"
    echo "Image:        ${IMAGE_ID}"
    echo "Shape:        ${SHAPE} ${OCPUS} OCPU / ${MEMORY_GB} GB, boot ${BOOT_VOLUME_GB} GB"
    echo "Legacy IMDS:  disabled=${LEGACY_IMDS_DISABLED}"
    echo "SSH from:     ${ALLOW_CIDR}"
    echo "Evidence:     ${OUTDIR}"
    echo ""

    ensure_network
    write_ignition

    local ad args=()
    ad="$(oci iam availability-domain list --compartment-id "${OCI_COMPARTMENT_ID}" --query 'data[0].name' --raw-output)"
    if [[ "${LEGACY_IMDS_DISABLED}" == "true" ]]; then
        args+=(--instance-options '{"areLegacyImdsEndpointsDisabled": true}')
    fi

    log "launch: ${INSTANCE_NAME} in ${ad}"
    local t0 instance_id
    t0="$(date +%s)"
    instance_id="$(oci compute instance launch \
        --compartment-id "${OCI_COMPARTMENT_ID}" --availability-domain "${ad}" \
        --display-name "${INSTANCE_NAME}" --hostname-label "${INSTANCE_NAME//[^a-z0-9]/}" \
        --shape "${SHAPE}" --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}" \
        --image-id "${IMAGE_ID}" --boot-volume-size-in-gbs "${BOOT_VOLUME_GB}" \
        --subnet-id "${SUBNET_ID}" --nsg-ids "[\"${NSG_ID}\"]" --assign-public-ip true \
        --user-data-file "${OUTDIR}/test.ign" \
        --freeform-tags "${TAGS}" "${args[@]}" \
        --query data.id --raw-output)"
    log "launch: ${instance_id}, waiting for RUNNING"
    wait_for_ssh "${instance_id}" "${t0}"
}

# Wait for an instance to reach RUNNING, get its public IP, wait for SSH,
# and write launch.json with the timings measured from t0 (epoch seconds).
wait_for_ssh() {
    local instance_id="$1" t0="$2" state t_running ip
    while true; do
        state="$(oci compute instance get --instance-id "${instance_id}" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo UNKNOWN)"
        case "${state}" in
            RUNNING) break ;;
            PROVISIONING|STARTING|UNKNOWN) sleep 10 ;;
            *) die "instance ${instance_id} is in state ${state}" ;;
        esac
    done
    t_running="$(date +%s)"
    log "launch: RUNNING after $((t_running - t0))s"

    ip=""
    for _ in $(seq 1 30); do
        ip="$(instance_public_ip "${instance_id}")"
        [[ -n "${ip}" && "${ip}" != "null" ]] && break
        sleep 5
    done
    [[ -n "${ip}" && "${ip}" != "null" ]] || die "no public IP on ${instance_id}"
    log "launch: public IP ${ip}, waiting up to ${SSH_WAIT_SECONDS}s for SSH"

    local t_ssh="" deadline=$(( $(date +%s) + SSH_WAIT_SECONDS ))
    while (( $(date +%s) < deadline )); do
        if ssh "${SSH_OPTS[@]}" "core@${ip}" true 2>/dev/null; then
            t_ssh="$(date +%s)"
            break
        fi
        sleep 10
    done
    if [[ -n "${t_ssh}" ]]; then
        log "launch: SSH up after $((t_ssh - t0))s from launch"
    else
        log "launch: SSH did not come up within ${SSH_WAIT_SECONDS}s, collect will still capture the console history"
    fi

    local ssh_s=null
    [[ -z "${t_ssh}" ]] || ssh_s=$((t_ssh - t0))
    jq -n --arg id "${instance_id}" --arg ip "${ip}" --arg name "${INSTANCE_NAME}" --arg image "${IMAGE_ID}" \
        --arg legacy "${LEGACY_IMDS_DISABLED}" --arg marker "${MARKER}" \
        --argjson launch_to_running "$((t_running - t0))" \
        --argjson launch_to_ssh "${ssh_s}" \
        '{instance_id: $id, public_ip: $ip, name: $name, image_id: $image, legacy_imds_disabled: ($legacy == "true"),
          marker: $marker, launch_to_running_s: $launch_to_running, launch_to_ssh_s: $launch_to_ssh}' \
        > "${OUTDIR}/launch.json"
    log "launch: wrote ${OUTDIR}/launch.json"
}

do_wait() {
    mkdir -p "${OUTDIR}"
    local instance_id created t0
    instance_id="$(find_instance)"
    [[ -n "${instance_id}" ]] || die "instance ${INSTANCE_NAME} not found"
    created="$(oci compute instance get --instance-id "${instance_id}" --query 'data."time-created"' --raw-output)"
    t0="$(date -d "${created}" +%s)"
    [[ -n "${IMAGE_ID}" ]] || IMAGE_ID="$(oci compute instance get --instance-id "${instance_id}" --query 'data."source-details"."image-id"' --raw-output)"
    log "wait: ${INSTANCE_NAME} (${instance_id}) created ${created}"
    wait_for_ssh "${instance_id}" "${t0}"
}

do_collect() {
    mkdir -p "${OUTDIR}"
    local instance_id ip
    instance_id="$(find_instance)"
    [[ -n "${instance_id}" ]] || die "instance ${INSTANCE_NAME} not found"
    ip="$(instance_public_ip "${instance_id}")"

    log "collect: console history"
    local hist
    hist="$(oci compute console-history capture --instance-id "${instance_id}" \
        --wait-for-state SUCCEEDED --max-wait-seconds 300 --query data.id --raw-output)"
    quiet oci compute console-history get-content --instance-console-history-id "${hist}" \
        --length 10000000 --file "${OUTDIR}/console-history.txt"
    oci compute console-history delete --instance-console-history-id "${hist}" --force >/dev/null || true
    oci compute instance get --instance-id "${instance_id}" > "${OUTDIR}/instance.json"

    if [[ -z "${ip}" || "${ip}" == "null" ]] || ! ssh "${SSH_OPTS[@]}" "core@${ip}" true 2>/dev/null; then
        log "collect: SSH not reachable, only the console history was captured"
        return 0
    fi

    log "collect: node evidence over SSH"
    local checks=(
        "cmdline:cat /proc/cmdline"
        "os-release:cat /etc/os-release"
        "hostname:hostname"
        "marker:cat /etc/rhcos-oci-marker"
        "rpm-ostree-status:rpm-ostree status"
        "df-root:df -h / /var /sysroot"
        "ignition-journal:journalctl -b --no-pager -u ignition-fetch-offline -u ignition-fetch -u ignition-disks -u ignition-mount -u ignition-files"
        "ignition-platform-journal:journalctl -b --no-pager | grep -iE 'ignition.*(platform|provider|fetch|user_data|opc/v)' | head -50"
        "imds-user-data:curl -sS -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/metadata/user_data | base64 -d | head -c 300"
        "imds-v1-probe:curl -sS -o /dev/null -w '%{http_code}' http://169.254.169.254/opc/v1/instance/ || true"
        "lsblk:lsblk"
    )
    local entry name cmd
    for entry in "${checks[@]}"; do
        name="${entry%%:*}"
        cmd="${entry#*:}"
        # shellcheck disable=SC2029  # the command string is meant to be built here
        ssh "${SSH_OPTS[@]}" "core@${ip}" "${cmd}" > "${OUTDIR}/${name}.txt" 2>&1 || echo "(exit $?)" >> "${OUTDIR}/${name}.txt"
    done

    echo ""
    echo "=== Summary ${INSTANCE_NAME} ==="
    if grep -q 'ignition.platform.id=oraclecloud' "${OUTDIR}/cmdline.txt"; then
        echo "platform id:   oraclecloud (ok)"
    else
        echo "platform id:   NOT oraclecloud: $(grep -o 'ignition.platform.id=[a-z]*' "${OUTDIR}/cmdline.txt" || echo missing)"
    fi
    if grep -qF "${MARKER%% *}" "${OUTDIR}/marker.txt" 2>/dev/null; then
        echo "marker file:   present (ok)"
    else
        echo "marker file:   $(head -c 120 "${OUTDIR}/marker.txt")"
    fi
    echo "hostname:      $(cat "${OUTDIR}/hostname.txt")"
    echo "os-release:    $(grep -E '^PRETTY_NAME' "${OUTDIR}/os-release.txt" | cut -d= -f2-)"
    echo "rpm-ostree:    $(grep -E 'Version:' "${OUTDIR}/rpm-ostree-status.txt" | head -1 | xargs)"
    echo "var fs:        $(grep -E " /var$" "${OUTDIR}/df-root.txt" | awk '{print $2 " total, " $5 " used"}')"
    echo "imds v1 probe: HTTP $(cat "${OUTDIR}/imds-v1-probe.txt")"
    echo "evidence:      ${OUTDIR}"
}

do_down() {
    local instance_id
    instance_id="$(find_instance)"
    if [[ -n "${instance_id}" ]]; then
        log "down: terminating ${INSTANCE_NAME} (${instance_id}) with its boot volume"
        quiet oci compute instance terminate --instance-id "${instance_id}" --preserve-boot-volume false --force \
            --wait-for-state SUCCEEDED --max-wait-seconds 900
    else
        log "down: no instance named ${INSTANCE_NAME}"
    fi

    [[ "${KEEP_NETWORK}" == "true" ]] && { log "down: keeping the network"; return 0; }

    local vcn others
    vcn="$(find_vcn)"
    [[ -n "${vcn}" ]] || { log "down: no VCN named ${NETWORK_NAME}"; return 0; }

    others="$(oci compute instance list --compartment-id "${OCI_COMPARTMENT_ID}" --all 2>/dev/null \
        | jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING") | ."display-name"] | join(" ")' 2>/dev/null || true)"
    if [[ -n "${others}" ]]; then
        log "down: other instances still exist in the compartment (${others}), keeping the network"
        return 0
    fi

    local nsg subnet igw rt
    nsg="$(find_nsg "${vcn}")"
    subnet="$(find_subnet "${vcn}")"
    igw="$(find_igw "${vcn}")"
    rt="$(oci network vcn get --vcn-id "${vcn}" --query 'data."default-route-table-id"' --raw-output)"
    log "down: deleting network ${NETWORK_NAME}"
    [[ -z "${subnet}" ]] || quiet oci network subnet delete --subnet-id "${subnet}" --force --wait-for-state TERMINATED
    [[ -z "${nsg}" ]] || quiet oci network nsg delete --nsg-id "${nsg}" --force --wait-for-state TERMINATED
    quiet oci network route-table update --rt-id "${rt}" --route-rules '[]' --force
    [[ -z "${igw}" ]] || oci network internet-gateway delete --ig-id "${igw}" --force --wait-for-state TERMINATED
    quiet oci network vcn delete --vcn-id "${vcn}" --force --wait-for-state TERMINATED
    log "down: network gone"
}

do_status() {
    echo "--- instances"
    oci compute instance list --compartment-id "${OCI_COMPARTMENT_ID}" --all 2>/dev/null \
        | jq -r '.data[]? | select(."lifecycle-state" != "TERMINATED") | "\(."display-name")\t\(."lifecycle-state")\t\(.id)"' || true
    echo "--- boot volumes"
    local ad
    ad="$(oci iam availability-domain list --compartment-id "${OCI_COMPARTMENT_ID}" --query 'data[0].name' --raw-output)"
    oci bv boot-volume list --compartment-id "${OCI_COMPARTMENT_ID}" --availability-domain "${ad}" --all 2>/dev/null \
        | jq -r '.data[]? | select(."lifecycle-state" != "TERMINATED") | "\(."display-name")\t\(."lifecycle-state")\t\(."size-in-gbs") GB"' || true
    echo "--- vcns"
    oci network vcn list --compartment-id "${OCI_COMPARTMENT_ID}" --all 2>/dev/null \
        | jq -r '.data[]? | select(."lifecycle-state" != "TERMINATED") | "\(."display-name")\t\(."lifecycle-state")\t\(."cidr-block")"' || true
}

if [[ -z "${OUTDIR}" ]]; then
    OUTDIR="./rhcos-oci-evidence/${INSTANCE_NAME}-$(date -u +%Y%m%dT%H%M%SZ)"
fi

case "${ACTION}" in
    up) do_up ;;
    wait) do_wait ;;
    collect) do_collect ;;
    down) do_down ;;
    status) do_status ;;
esac
