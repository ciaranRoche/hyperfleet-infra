#!/usr/bin/env bash
set -euo pipefail

# Build an OCI custom image from a published RHCOS platform artifact.
#
# Reads the artifact location and checksums from an RHCOS stream JSON (the
# file openshift-install embeds, also published in the openshift/installer
# repository under data/data/coreos/), downloads and verifies it, uploads it
# to Object Storage, imports it as a paravirtualized custom image, applies the
# image capability schema and adds the worker shape to the image.
#
# Every step is idempotent on the RHCOS build id, so a re-run after a failure
# resumes where it stopped.
#
# Usage:
#   scripts/oci-rhcos-image.sh <download|upload|import|schema|all|print-image-id|info>
#
# Required:
#   OCI_COMPARTMENT_ID   compartment the bucket and image live in
# Optional:
#   RHCOS_STREAM_JSON    path or URL of the stream JSON
#                        (default: installer release-4.22 coreos-rhel-10.json)
#   RHCOS_PLATFORM       artifact platform (default: oraclecloud)
#   RHCOS_ARCH           architecture (default: x86_64)
#   BUCKET               Object Storage bucket (default: rhcos-images)
#   WORKDIR              local cache for downloads (default: ~/.cache/oci-rhcos)
#   SHAPE                shape added to the image (default: VM.Standard.E5.Flex)
#   OWNER_TAG            value of the owner freeform tag (default: $USER)
#   PURPOSE_TAG          value of the purpose freeform tag (default: oci-on-oke-poc)
#   LOCAL_QCOW2          import this locally built QCOW2 instead of a stream artifact
#   LOCAL_BUILD          its RHCOS build id (required with LOCAL_QCOW2)
#
# Standard OCI CLI auth variables apply (OCI_CLI_PROFILE, OCI_CLI_AUTH).

RHCOS_STREAM_JSON="${RHCOS_STREAM_JSON:-https://raw.githubusercontent.com/openshift/installer/release-4.22/data/data/coreos/coreos-rhel-10.json}"
RHCOS_PLATFORM="${RHCOS_PLATFORM:-oraclecloud}"
RHCOS_ARCH="${RHCOS_ARCH:-x86_64}"
BUCKET="${BUCKET:-rhcos-images}"
WORKDIR="${WORKDIR:-${HOME}/.cache/oci-rhcos}"
SHAPE="${SHAPE:-VM.Standard.E5.Flex}"
OWNER_TAG="${OWNER_TAG:-${USER:-unknown}}"
PURPOSE_TAG="${PURPOSE_TAG:-oci-on-oke-poc}"
OCI_COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"

usage() {
    sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

die() {
    echo "ERROR: $*" >&2
    exit 1
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

for c in oci jq curl sha256sum gzip; do need_cmd "$c"; done

ACTION="${1:-}"
case "${ACTION}" in
    download|upload|import|schema|all|print-image-id|info) ;;
    *) usage ;;
esac

[[ -n "${OCI_COMPARTMENT_ID}" ]] || die "OCI_COMPARTMENT_ID is required"
[[ "${OCI_COMPARTMENT_ID}" == ocid1.compartment.* ]] || die "OCI_COMPARTMENT_ID does not look like a compartment OCID"

mkdir -p "${WORKDIR}/downloads"

# --- stream -------------------------------------------------------------------

LOCAL_QCOW2="${LOCAL_QCOW2:-}"
LOCAL_BUILD="${LOCAL_BUILD:-}"

if [[ -n "${LOCAL_QCOW2}" ]]; then
    # A QCOW2 built locally (scripts/oci-rhcos-metal-image.sh) instead of a
    # published artifact. No stream lookup, no download.
    [[ -f "${LOCAL_QCOW2}" ]] || die "LOCAL_QCOW2 not found: ${LOCAL_QCOW2}"
    [[ -n "${LOCAL_BUILD}" ]] || die "LOCAL_BUILD (the RHCOS build id) is required with LOCAL_QCOW2"
    STREAM_NAME="local"
    BUILD="${LOCAL_BUILD}"
    FORMAT="qcow2"
    LOCATION="${LOCAL_QCOW2}"
    SHA256=""
    USHA256=""
    IMAGE_NAME="rhcos-${BUILD}-${RHCOS_PLATFORM}-${RHCOS_ARCH}-from-metal"
    COMPRESSED_FILE=""
    QCOW2_FILE="${LOCAL_QCOW2}"
else
STREAM_FILE="${WORKDIR}/stream.json"
if [[ "${RHCOS_STREAM_JSON}" == http://* || "${RHCOS_STREAM_JSON}" == https://* ]]; then
    curl -fsSL --retry 3 -o "${STREAM_FILE}" "${RHCOS_STREAM_JSON}"
else
    [[ -f "${RHCOS_STREAM_JSON}" ]] || die "stream file not found: ${RHCOS_STREAM_JSON}"
    cp "${RHCOS_STREAM_JSON}" "${STREAM_FILE}"
fi

ARTIFACT_PATH=".architectures[\"${RHCOS_ARCH}\"].artifacts[\"${RHCOS_PLATFORM}\"]"
STREAM_NAME="$(jq -r '.stream // "unknown"' "${STREAM_FILE}")"
BUILD="$(jq -r "${ARTIFACT_PATH}.release // empty" "${STREAM_FILE}")"
[[ -n "${BUILD}" ]] || die "stream '${STREAM_NAME}' has no ${RHCOS_PLATFORM} artifact for ${RHCOS_ARCH}. This is the case for releases before 4.22; use the metal image route instead."

FORMAT="$(jq -r "${ARTIFACT_PATH}.formats | keys[0]" "${STREAM_FILE}")"
LOCATION="$(jq -r "${ARTIFACT_PATH}.formats[\"${FORMAT}\"].disk.location" "${STREAM_FILE}")"
SHA256="$(jq -r "${ARTIFACT_PATH}.formats[\"${FORMAT}\"].disk.sha256" "${STREAM_FILE}")"
USHA256="$(jq -r "${ARTIFACT_PATH}.formats[\"${FORMAT}\"].disk[\"uncompressed-sha256\"] // empty" "${STREAM_FILE}")"

[[ "${FORMAT}" == "qcow2.gz" ]] || die "unsupported artifact format '${FORMAT}', this script handles qcow2.gz"

IMAGE_NAME="rhcos-${BUILD}-${RHCOS_PLATFORM}-${RHCOS_ARCH}"
COMPRESSED_FILE="${WORKDIR}/downloads/$(basename "${LOCATION}")"
QCOW2_FILE="${WORKDIR}/downloads/${IMAGE_NAME}.qcow2"
fi
OBJECT_NAME="${IMAGE_NAME}.qcow2"
TAGS="{\"owner\":\"${OWNER_TAG}\",\"purpose\":\"${PURPOSE_TAG}\",\"rhcos-build\":\"${BUILD}\"}"

echo "=== RHCOS image for OCI ==="
echo "Stream:       ${STREAM_NAME}"
echo "Build:        ${BUILD}"
echo "Platform:     ${RHCOS_PLATFORM} (${RHCOS_ARCH})"
echo "Artifact:     ${LOCATION}"
echo "Image name:   ${IMAGE_NAME}"
echo "Bucket:       ${BUCKET}"
echo "Compartment:  ${OCI_COMPARTMENT_ID}"
echo "Work dir:     ${WORKDIR}"
echo ""

[[ "${ACTION}" == "info" ]] && exit 0

# --- helpers ------------------------------------------------------------------

sha_matches() {
    local file="$1" expected="$2"
    [[ -f "${file}" ]] || return 1
    [[ -n "${expected}" ]] || return 1
    echo "${expected}  ${file}" | sha256sum --check --status
}

namespace() {
    oci os ns get --query data --raw-output
}

# `oci ... list` prints nothing at all for an empty result, so always feed
# the output through jq with a default.
find_image_id() {
    oci compute image list \
        --compartment-id "${OCI_COMPARTMENT_ID}" \
        --display-name "${IMAGE_NAME}" \
        --all 2>/dev/null \
        | jq -r '[.data[] | select(."lifecycle-state" != "DELETED" and ."lifecycle-state" != "DELETING")][0].id // empty' 2>/dev/null || true
}

# Poll instead of --wait-for-state so a long import survives CLI hiccups and
# the state is checked explicitly.
wait_available() {
    local image_id="$1" state
    while true; do
        state="$(oci compute image get --image-id "${image_id}" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo UNKNOWN)"
        case "${state}" in
            AVAILABLE) return 0 ;;
            IMPORTING|PROVISIONING|UNKNOWN) sleep 30 ;;
            *) die "image ${image_id} is in state ${state}" ;;
        esac
    done
}

# --- steps --------------------------------------------------------------------

do_download() {
    if [[ -n "${LOCAL_QCOW2}" ]]; then
        echo "download: using local ${QCOW2_FILE}, nothing to fetch"
        return 0
    fi
    if sha_matches "${COMPRESSED_FILE}" "${SHA256}"; then
        echo "download: ${COMPRESSED_FILE} already present with matching sha256"
    else
        echo "download: fetching ${LOCATION}"
        curl -fL --retry 3 --progress-bar -o "${COMPRESSED_FILE}.part" "${LOCATION}"
        mv "${COMPRESSED_FILE}.part" "${COMPRESSED_FILE}"
        sha_matches "${COMPRESSED_FILE}" "${SHA256}" || die "sha256 mismatch on ${COMPRESSED_FILE}"
        echo "download: sha256 verified"
    fi

    if [[ -n "${USHA256}" ]] && sha_matches "${QCOW2_FILE}" "${USHA256}"; then
        echo "download: ${QCOW2_FILE} already decompressed with matching sha256"
    else
        echo "download: decompressing to ${QCOW2_FILE}"
        gzip -dc "${COMPRESSED_FILE}" > "${QCOW2_FILE}.part"
        mv "${QCOW2_FILE}.part" "${QCOW2_FILE}"
        if [[ -n "${USHA256}" ]]; then
            sha_matches "${QCOW2_FILE}" "${USHA256}" || die "uncompressed sha256 mismatch on ${QCOW2_FILE}"
            echo "download: uncompressed sha256 verified"
        fi
    fi
    echo "download: size $(du -h "${QCOW2_FILE}" | cut -f1)"
}

do_upload() {
    [[ -f "${QCOW2_FILE}" ]] || die "run download first, ${QCOW2_FILE} is missing"
    local ns
    ns="$(namespace)"

    if oci os bucket get --namespace "${ns}" --bucket-name "${BUCKET}" >/dev/null 2>&1; then
        echo "upload: bucket ${BUCKET} exists"
    else
        echo "upload: creating bucket ${BUCKET}"
        quiet oci os bucket create --namespace "${ns}" --compartment-id "${OCI_COMPARTMENT_ID}" \
            --name "${BUCKET}" --public-access-type NoPublicAccess \
            --freeform-tags "${TAGS}"
    fi

    if oci os object head --namespace "${ns}" --bucket-name "${BUCKET}" --name "${OBJECT_NAME}" >/dev/null 2>&1; then
        echo "upload: object ${OBJECT_NAME} already in ${BUCKET}"
    else
        echo "upload: putting ${OBJECT_NAME} into ${BUCKET}"
        local start=${SECONDS}
        oci os object put --namespace "${ns}" --bucket-name "${BUCKET}" --name "${OBJECT_NAME}" \
            --file "${QCOW2_FILE}" --parallel-upload-count 8 --part-size 128 --no-overwrite >/dev/null
        echo "upload: done in $((SECONDS - start))s"
    fi
}

do_import() {
    local image_id
    image_id="$(find_image_id)"
    if [[ -n "${image_id}" ]]; then
        echo "import: image ${IMAGE_NAME} already exists (${image_id})"
        wait_available "${image_id}"
    else
        local ns
        ns="$(namespace)"
        oci os object head --namespace "${ns}" --bucket-name "${BUCKET}" --name "${OBJECT_NAME}" >/dev/null 2>&1 \
            || die "run upload first, ${OBJECT_NAME} is not in ${BUCKET}"
        echo "import: importing ${OBJECT_NAME} as ${IMAGE_NAME}"
        local start=${SECONDS}
        image_id="$(oci compute image import from-object \
            --compartment-id "${OCI_COMPARTMENT_ID}" \
            --namespace "${ns}" --bucket-name "${BUCKET}" --name "${OBJECT_NAME}" \
            --source-image-type QCOW2 --launch-mode PARAVIRTUALIZED \
            --display-name "${IMAGE_NAME}" \
            --operating-system "Red Hat Enterprise Linux CoreOS" \
            --operating-system-version "${BUILD}" \
            --freeform-tags "${TAGS}" \
            --query data.id --raw-output)"
        echo "import: ${image_id}, waiting for AVAILABLE"
        wait_available "${image_id}"
        echo "import: AVAILABLE after $((SECONDS - start))s"
    fi
    echo "${image_id}" > "${WORKDIR}/${IMAGE_NAME}.image-id"
}

do_schema() {
    local image_id
    image_id="$(find_image_id)"
    [[ -n "${image_id}" ]] || die "run import first, image ${IMAGE_NAME} not found"

    local existing
    existing="$(oci compute image-capability-schema list \
        --compartment-id "${OCI_COMPARTMENT_ID}" --image-id "${image_id}" --all 2>/dev/null \
        | jq -r '.data | length' 2>/dev/null || echo 0)"
    if [[ "${existing:-0}" -gt 0 ]]; then
        echo "schema: image already has a capability schema"
    else
        local version
        version="$(oci compute global-image-capability-schema list \
            --query 'data[0]."current-version-name"' --raw-output)"
        [[ -n "${version}" && "${version}" != "null" ]] || die "could not read the global image capability schema version"
        echo "schema: applying UEFI_64 paravirtualized VM schema (global version ${version})"
        # The same shape Oracle's own OpenShift on OCI Terraform applies to VM images.
        local schema_data
        schema_data="$(jq -nc '{
            "Compute.Firmware": {descriptorType: "enumstring", source: "IMAGE", defaultValue: "UEFI_64", values: ["UEFI_64"]},
            "Compute.LaunchMode": {descriptorType: "enumstring", source: "IMAGE", defaultValue: "PARAVIRTUALIZED", values: ["NATIVE", "EMULATED", "PARAVIRTUALIZED", "CUSTOM"]},
            "Storage.BootVolumeType": {descriptorType: "enumstring", source: "IMAGE", defaultValue: "PARAVIRTUALIZED", values: ["ISCSI", "SCSI", "IDE", "PARAVIRTUALIZED"]},
            "Storage.LocalDataVolumeType": {descriptorType: "enumstring", source: "IMAGE", defaultValue: "PARAVIRTUALIZED", values: ["ISCSI", "SCSI", "IDE", "PARAVIRTUALIZED"]},
            "Storage.RemoteDataVolumeType": {descriptorType: "enumstring", source: "IMAGE", defaultValue: "PARAVIRTUALIZED", values: ["ISCSI", "SCSI", "IDE", "PARAVIRTUALIZED"]},
            "Storage.Iscsi.MultipathDeviceSupported": {descriptorType: "boolean", source: "IMAGE", defaultValue: false}
        }')"
        quiet oci compute image-capability-schema create \
            --compartment-id "${OCI_COMPARTMENT_ID}" --image-id "${image_id}" \
            --global-image-capability-schema-version-name "${version}" \
            --schema-data "${schema_data}" --freeform-tags "${TAGS}"
        echo "schema: applied"
    fi

    local shapes
    shapes="$(oci compute image-shape-compatibility-entry list --image-id "${image_id}" --all 2>/dev/null \
        | jq -r '[.data[].shape] | join(" ")' 2>/dev/null || true)"
    if [[ " ${shapes} " == *" ${SHAPE} "* ]]; then
        echo "schema: shape ${SHAPE} already on the image"
    else
        echo "schema: adding shape ${SHAPE}"
        quiet oci compute image-shape-compatibility-entry add --image-id "${image_id}" --shape-name "${SHAPE}"
    fi
}

do_print_image_id() {
    local image_id
    image_id="$(find_image_id)"
    [[ -n "${image_id}" ]] || die "image ${IMAGE_NAME} not found"
    echo "${image_id}"
}

case "${ACTION}" in
    download) do_download ;;
    upload) do_upload ;;
    import) do_import ;;
    schema) do_schema ;;
    all) do_download; do_upload; do_import; do_schema; echo ""; echo "Image ID: $(do_print_image_id)" ;;
    print-image-id) do_print_image_id ;;
esac
