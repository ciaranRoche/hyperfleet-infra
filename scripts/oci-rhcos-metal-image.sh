#!/usr/bin/env bash
set -euo pipefail

# Build an OCI-bootable RHCOS QCOW2 from the published `metal` image, for
# releases whose RHCOS stream has no `oraclecloud` artifact (4.21 and older).
#
# The metal image is written to a loop device with
# `coreos-installer install --platform oraclecloud`, which only changes the
# Ignition platform id in the bootloader entries, then converted to QCOW2.
# Hand the result to scripts/oci-rhcos-image.sh with LOCAL_QCOW2 and
# LOCAL_BUILD set to upload and import it.
#
# Needs root for the loop device. Run it with sudo, or as root.
#
# Usage:
#   sudo -E scripts/oci-rhcos-metal-image.sh <download|build|verify|all>
#
# Optional:
#   RHCOS_STREAM_JSON    path or URL of the stream JSON
#                        (default: installer release-4.21 rhcos.json)
#   RHCOS_ARCH           (default: x86_64)
#   WORKDIR              (default: ~/.cache/oci-rhcos of the invoking user)
#   DISK_GB              size of the virtual disk written (default: 16)
#   COREOS_INSTALLER     binary to use; falls back to the upstream container
#                        through podman when missing (default: coreos-installer)

RHCOS_STREAM_JSON="${RHCOS_STREAM_JSON:-https://raw.githubusercontent.com/openshift/installer/release-4.21/data/data/coreos/rhcos.json}"
RHCOS_ARCH="${RHCOS_ARCH:-x86_64}"
WORKDIR="${WORKDIR:-${HOME}/.cache/oci-rhcos}"
DISK_GB="${DISK_GB:-16}"
COREOS_INSTALLER="${COREOS_INSTALLER:-coreos-installer}"
PLATFORM=oraclecloud

usage() {
    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

for c in jq curl sha256sum qemu-img losetup; do need_cmd "$c"; done

ACTION="${1:-}"
case "${ACTION}" in
    download|build|verify|all) ;;
    *) usage ;;
esac

mkdir -p "${WORKDIR}/downloads"

STREAM_FILE="${WORKDIR}/stream-metal.json"
if [[ "${RHCOS_STREAM_JSON}" == http://* || "${RHCOS_STREAM_JSON}" == https://* ]]; then
    curl -fsSL --retry 3 -o "${STREAM_FILE}" "${RHCOS_STREAM_JSON}"
else
    [[ -f "${RHCOS_STREAM_JSON}" ]] || die "stream file not found: ${RHCOS_STREAM_JSON}"
    cp "${RHCOS_STREAM_JSON}" "${STREAM_FILE}"
fi

METAL=".architectures[\"${RHCOS_ARCH}\"].artifacts.metal"
STREAM_NAME="$(jq -r '.stream // "unknown"' "${STREAM_FILE}")"
BUILD="$(jq -r "${METAL}.release // empty" "${STREAM_FILE}")"
[[ -n "${BUILD}" ]] || die "stream '${STREAM_NAME}' has no metal artifact for ${RHCOS_ARCH}"
LOCATION="$(jq -r "${METAL}.formats[\"raw.gz\"].disk.location" "${STREAM_FILE}")"
SHA256="$(jq -r "${METAL}.formats[\"raw.gz\"].disk.sha256" "${STREAM_FILE}")"
HAS_ORACLECLOUD="$(jq -r ".architectures[\"${RHCOS_ARCH}\"].artifacts | has(\"${PLATFORM}\")" "${STREAM_FILE}")"

METAL_FILE="${WORKDIR}/downloads/$(basename "${LOCATION}")"
RAW_FILE="${WORKDIR}/downloads/rhcos-${BUILD}-${PLATFORM}-${RHCOS_ARCH}-from-metal.raw"
QCOW2_FILE="${WORKDIR}/downloads/rhcos-${BUILD}-${PLATFORM}-${RHCOS_ARCH}-from-metal.qcow2"

echo "=== RHCOS metal image to OCI QCOW2 ==="
echo "Stream:       ${STREAM_NAME}"
echo "Build:        ${BUILD}"
echo "Metal image:  ${LOCATION}"
echo "Output:       ${QCOW2_FILE}"
echo "Disk size:    ${DISK_GB} GB"
if [[ "${HAS_ORACLECLOUD}" == "true" ]]; then
    echo "Note:         this stream already publishes an ${PLATFORM} artifact, prefer scripts/oci-rhcos-image.sh"
fi
echo ""

sha_matches() {
    echo "$2  $1" | sha256sum --check --status 2>/dev/null
}

do_download() {
    if sha_matches "${METAL_FILE}" "${SHA256}"; then
        echo "download: ${METAL_FILE} already present with matching sha256"
    else
        echo "download: fetching ${LOCATION}"
        curl -fL --retry 3 --progress-bar -o "${METAL_FILE}.part" "${LOCATION}"
        mv "${METAL_FILE}.part" "${METAL_FILE}"
        sha_matches "${METAL_FILE}" "${SHA256}" || die "sha256 mismatch on ${METAL_FILE}"
        echo "download: sha256 verified"
    fi
}

run_installer() {
    if command -v "${COREOS_INSTALLER}" >/dev/null 2>&1; then
        "${COREOS_INSTALLER}" "$@"
    else
        need_cmd podman
        echo "build: coreos-installer not installed, using quay.io/coreos/coreos-installer:release"
        podman run --rm --privileged -v /dev:/dev -v "${WORKDIR}/downloads:${WORKDIR}/downloads" \
            quay.io/coreos/coreos-installer:release "$@"
    fi
}

do_build() {
    [[ "$(id -u)" == "0" ]] || die "build needs root for the loop device, run with sudo -E"
    sha_matches "${METAL_FILE}" "${SHA256}" || die "run download first"
    if [[ -f "${QCOW2_FILE}" ]]; then
        echo "build: ${QCOW2_FILE} already exists, delete it to rebuild"
        return 0
    fi

    rm -f "${RAW_FILE}"
    truncate -s "${DISK_GB}G" "${RAW_FILE}"
    local loop
    loop="$(losetup --find --show --partscan "${RAW_FILE}")"
    echo "build: ${RAW_FILE} on ${loop}"
    # shellcheck disable=SC2064  # expand loop now, it is what we want to detach
    trap "losetup -d '${loop}' 2>/dev/null || true" EXIT

    local start=${SECONDS}
    run_installer install --platform "${PLATFORM}" --image-file "${METAL_FILE}" "${loop}"
    echo "build: coreos-installer done in $((SECONDS - start))s"

    verify_loop "${loop}"

    losetup -d "${loop}"
    trap - EXIT

    echo "build: converting to QCOW2"
    qemu-img convert -f raw -O qcow2 "${RAW_FILE}" "${QCOW2_FILE}"
    rm -f "${RAW_FILE}"
    if [[ -n "${SUDO_UID:-}" ]]; then
        chown "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "${QCOW2_FILE}"
    fi
    echo "build: $(du -h "${QCOW2_FILE}" | cut -f1) at ${QCOW2_FILE}"
    echo ""
    echo "Next: LOCAL_QCOW2=${QCOW2_FILE} LOCAL_BUILD=${BUILD} scripts/oci-rhcos-image.sh all"
}

# Mount the boot partition read only and check the bootloader entries carry
# the platform id. Partition 3 is /boot on RHCOS images.
verify_loop() {
    local loop="$1" mnt
    mnt="$(mktemp -d)"
    mount -o ro "${loop}p3" "${mnt}"
    local ids
    ids="$(grep -rhoE 'ignition\.platform\.id=[a-z]+' "${mnt}/loader/entries/" 2>/dev/null | sort -u | tr '\n' ' ')"
    umount "${mnt}"
    rmdir "${mnt}"
    echo "verify: bootloader entries carry: ${ids:-nothing}"
    [[ "${ids}" == "ignition.platform.id=${PLATFORM} " ]] || die "platform id is not ${PLATFORM}"
}

do_verify() {
    [[ "$(id -u)" == "0" ]] || die "verify needs root for the loop device, run with sudo -E"
    [[ -f "${QCOW2_FILE}" ]] || die "no ${QCOW2_FILE}, run build first"
    local raw loop
    raw="$(mktemp --suffix=.raw)"
    qemu-img convert -f qcow2 -O raw "${QCOW2_FILE}" "${raw}"
    loop="$(losetup --find --show --partscan "${raw}")"
    # shellcheck disable=SC2064
    trap "losetup -d '${loop}' 2>/dev/null || true; rm -f '${raw}'" EXIT
    verify_loop "${loop}"
}

case "${ACTION}" in
    download) do_download ;;
    build) do_build ;;
    verify) do_verify ;;
    all) do_download; do_build ;;
esac
