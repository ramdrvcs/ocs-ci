#!/usr/bin/env bash
# Wipe block devices so they are safe for ODF / LSO reuse on bare metal.
#
# Clears filesystem signatures, GPT via sgdisk when available, and Ceph
# BlueStore labels at offset 0 and 1GiB/10GiB/100GiB/1000GiB/...
# Docs: https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/
# IBM ODF disk wipe: sgdisk --zap-all + dd at those offsets (when sgdisk exists).
#
# Usage:
#   clean_disk_for_odf_reuse.sh --auto
#   clean_disk_for_odf_reuse.sh --auto --no-gpt /dev/disk/by-path/...-part5
#   clean_disk_for_odf_reuse.sh /dev/sdb /dev/sdc
#   clean_disk_for_odf_reuse.sh --no-gpt /dev/disk/by-path/...-part5
#
# --auto discovers non-boot whole disks (same rules as disks_available_to_cleanup:
# skip rom/nbd, exclude the parent of a partition mounted at /boot).
# Devices after --no-gpt skip GPT wipe (wipefs + BlueStore offsets only).
# If sgdisk is missing on the host, GPT zap is skipped (same as prior ocs-ci).

set -euo pipefail

usage() {
    echo "Usage: $0 --auto [--no-gpt <device> ...]"
    echo "       $0 <device> [device...] [--no-gpt <device> ...]"
    echo "  Wipe devices for ODF/LSO reuse (wipefs, GPT, BlueStore labels)."
}

# Print /dev/<name> for each whole disk that is safe to wipe (stdout only).
discover_eligible_disks() {
    local name pkname type mnt
    local boot_parents=""

    while read -r name pkname type mnt; do
        [[ -z "${name}" ]] && continue
        [[ "${type}" == "rom" ]] && continue
        [[ "${name}" == *nbd* ]] && continue
        if [[ "${type}" == "part" && "${mnt}" == "/boot" ]]; then
            boot_parents="${boot_parents} ${pkname} "
        fi
    done < <(lsblk -nr -o NAME,PKNAME,TYPE,MOUNTPOINT)

    while read -r name type; do
        [[ -z "${name}" ]] && continue
        [[ "${type}" != "disk" ]] && continue
        [[ "${name}" == *nbd* ]] && continue
        if [[ " ${boot_parents} " == *" ${name} "* ]]; then
            continue
        fi
        echo "/dev/${name}"
    done < <(lsblk -nr -o NAME,TYPE)
}

clean_one_device() {
    local device="$1"
    local run_gpt_wipe="$2"

    echo "STEP: cleaning ${device}"

    if [[ ! -b "${device}" ]]; then
        echo "ERROR: ${device} is not a block device"
        exit 1
    fi

    echo "STEP: wipefs ${device}"
    wipefs -a -f "${device}"

    if [[ "${run_gpt_wipe}" -eq 1 ]]; then
        if command -v sgdisk >/dev/null 2>&1; then
            echo "STEP: sgdisk --zap-all ${device}"
            sgdisk --zap-all "${device}"
        else
            echo "STEP: sgdisk not found; skipping sgdisk --zap-all for ${device} (wipefs and bluestore dd cleanup still run)"
        fi
    else
        echo "STEP: skipping GPT wipe for ${device}"
    fi

    local size
    size="$(lsblk -n -b -o SIZE "${device}" | tr -d '[:space:]')"
    if [[ -z "${size}" || "${size}" -le 0 ]]; then
        echo "ERROR: could not determine size for ${device}"
        exit 1
    fi

    echo "STEP: bluestore wipe ${device} size=${size}"
    dd if=/dev/zero of="${device}" bs=1M count=1 seek=0 conv=fsync

    local seek=1073741824
    while [[ "${seek}" -lt "${size}" ]]; do
        dd if=/dev/zero of="${device}" bs=1M count=1 seek="$((seek / 1048576))" conv=fsync
        seek=$((seek * 10))
    done

    echo "STEP: done ${device}"
}

auto=0
run_gpt_wipe=1
cleaned=0
declare -a gpt_devices=()
declare -a nogpt_devices=()

for arg in "$@"; do
    if [[ "${arg}" == "--auto" ]]; then
        auto=1
        continue
    fi
    if [[ "${arg}" == "--no-gpt" ]]; then
        run_gpt_wipe=0
        continue
    fi
    if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
        usage
        exit 0
    fi
    if [[ "${arg}" != /dev/* ]]; then
        echo "ERROR: expected device path under /dev, got: ${arg}"
        usage
        exit 1
    fi
    if [[ "${run_gpt_wipe}" -eq 1 ]]; then
        gpt_devices+=("${arg}")
    else
        nogpt_devices+=("${arg}")
    fi
done

if [[ "${auto}" -eq 1 ]]; then
    echo "STEP: auto-discovering disks to wipe"
    while read -r dev; do
        [[ "${dev}" == /dev/* ]] || continue
        echo "STEP: discover candidate ${dev}"
        gpt_devices+=("${dev}")
    done < <(discover_eligible_disks)
fi

if [[ "${#gpt_devices[@]}" -eq 0 && "${#nogpt_devices[@]}" -eq 0 ]]; then
    echo "ERROR: no devices to clean (pass --auto and/or device paths)"
    usage
    exit 1
fi

for device in "${gpt_devices[@]+"${gpt_devices[@]}"}"; do
    clean_one_device "${device}" 1
    cleaned=$((cleaned + 1))
done

for device in "${nogpt_devices[@]+"${nogpt_devices[@]}"}"; do
    clean_one_device "${device}" 0
    cleaned=$((cleaned + 1))
done

echo "DONE: cleaned ${cleaned} device(s)"
