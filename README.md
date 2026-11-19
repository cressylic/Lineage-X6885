# LineageOS 23.2 All-in-One Device Tree for Infinix X6885
## WIP
## Device Specifications

| Property | Value |
|:---|:---|
| **Device** | Infinix X6885 (Infinix-X6885 / X6885-OP) |
| **Chipset** | MediaTek Helio G99 (MT6789) |
| **Architecture** | arm64-v8a (64-bit only, armv8.2-a) |
| **Android Version** | 16 (LineageOS 23.2) |
| **Kernel Layout** | Inline GKI LZ4 (`boot`), DTB (`vendor_boot`), DTBO (`dtbo`) |
| **Storage** | Dynamic Partitions (Virtual A/B) |

---

## Prerequisites

Initialize and sync LineageOS 23.2 source:

```bash
mkdir -p ~/lineage && cd ~/lineage
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs
repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
```

---

## Build Guide

### 1. Place Device Tree

Clone or place this repository into your source root:

```
device/infinix/X6885
```

### 2. Clone Required Dependencies

Run inside the source root (`~/lineage`):

```bash
# MediaTek HALs
git clone https://github.com/LineageOS/android_hardware_mediatek.git -b lineage-23.2 hardware/mediatek

# MediaTek SEPolicy
git clone https://github.com/LineageOS/android_device_mediatek_sepolicy_vndr.git -b lineage-23.2 device/mediatek/sepolicy_vndr

# Google Interfaces (Power HAL dependency)
git clone https://github.com/LineageOS/android_hardware_google_interfaces.git -b lineage-23.2 hardware/google/interfaces
```

### 3. Pull Git LFS Binaries

```bash
git -C device/infinix/X6885 lfs pull
```

### 4. Build the ROM

```bash
source build/envsetup.sh
lunch lineage_X6885-ap3a-userdebug
m bacon -j$(nproc --all)
```

Target variants available:
- `lineage_X6885-ap3a-userdebug` (Recommended for testing and debugging)
- `lineage_X6885-ap3a-user` (Production release)
- `lineage_X6885-ap3a-eng` (Engineering build)

---

## Flashing Instructions

Make sure the bootloader is unlocked:

```bash
fastboot flashing unlock
```

Flash the generated boot images:

```bash
# Flash kernel & boot partitions
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vendor_boot vendor_boot.img

# Reboot into Fastbootd
fastboot reboot fastboot
