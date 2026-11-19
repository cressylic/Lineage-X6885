#!/bin/bash
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

add_lunch_combo lineage_X6885-ap3a-user
add_lunch_combo lineage_X6885-ap3a-userdebug
add_lunch_combo lineage_X6885-ap3a-eng

_device_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_aosp_root="$(cd "$_device_dir/../../../.." && pwd)"
_patches_dir="$_device_dir/patches"

# Map component directories to AOSP tree paths
_target_path() {
    local comp="$1"
    case "$comp" in
        frameworks_base) echo "frameworks/base" ;;
        frameworks_native) echo "frameworks/native" ;;
        system_core) echo "system/core" ;;
        hardware_mediatek) echo "hardware/mediatek" ;;
        hardware_google_pixel) echo "hardware/google/pixel" ;;
        device_mediatek_sepolicy_vndr) echo "device/mediatek/sepolicy_vndr" ;;
        *) echo "${comp//_//}" ;;
    esac
}

apply_patches() {
    if [[ ! -d "$_patches_dir" ]]; then
        return 0
    fi

    for comp_dir in "$_patches_dir"/*; do
        [[ -d "$comp_dir" ]] || continue
        local target_repo="$_aosp_root/$(_target_path "$(basename "$comp_dir")")"

        if [[ ! -d "$target_repo" ]]; then
            continue
        fi

        for patch_file in "$comp_dir"/*.patch; do
            [[ -f "$patch_file" ]] || continue
            if git -C "$target_repo" apply --check "$patch_file" 2>/dev/null; then
                git -C "$target_repo" apply "$patch_file"
            fi
        done
    done
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    apply_patches
fi
