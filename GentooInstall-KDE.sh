#!/usr/bin/env bash
set -euo pipefail

bail() { echo "ERROR: $*" >&2; exit 1; }
ask() { local prompt="$1"; read -r -p "$prompt" REPLY && echo "$REPLY"; }
confirm() { read -r -p "$1 [y/N]: " ans; [[ "${ans,,}" == "y" ]]; }

# Minimum tools on the host (we don't include emerge or eselect)
for c in parted mkfs.ext4 mkfs.btrfs mkswap swapon wget tar curl lsblk blkid sed awk mount umount chroot; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "Missing tool: $c. Install it in the live environment before continuing."
    bail "Insufficient tools."
  fi
done

[[ $EUID -eq 0 ]] || bail "Run as root from the live environment"

echo "=== Gentoo Installer amd64 OpenRC + KDE + PipeWire (robust) ==="

# --- User inputs ---
BOOT_TYPE=""
while [[ -z "$BOOT_TYPE" ]]; do
  bt=$(ask "Boot type? (uefi/bios): ")
  case "${bt,,}" in uefi|bios) BOOT_TYPE="${bt,,}";; *) echo "Choose 'uefi' or 'bios'";;
  esac
done

FS_TYPE=""
while [[ -z "$FS_TYPE" ]]; do
  fs=$(ask "Filesystem for root (ext4/btrfs): ")
  case "${fs,,}" in ext4|btrfs) FS_TYPE="${fs,,}";; *) echo "Choose 'ext4' or 'btrfs'";;
  esac
done

DISK=$(ask "Target disk (e.g. /dev/sda, /dev/nvme0n1): ")
[[ -b "$DISK" ]] || bail "Invalid disk: $DISK"
confirm "ALL data on $DISK will be erased! Continue?" || bail "Cancelled"

if [[ "$BOOT_TYPE" == "uefi" ]]; then
  echo "Note: SWAP will use all remaining disk space after EFI (1GB) and ROOT"
else
  echo "Note: SWAP will use all remaining disk space after ROOT"
fi
ROOT_GB=$(ask "Root size in GB (remaining space will be SWAP): ")
HOSTNAME=$(ask "Hostname: ")
USERNAME=$(ask "Username: ")

echo "Enter password for root:"
read -s ROOT_PASS
echo
echo "Enter password for user '$USERNAME':"
read -s USER_PASS
echo

GPU=$(ask "Primary GPU (amdgpu/nvidia/intel/modesetting): ")
GPU=${GPU:-modesetting}

echo
echo "Summary:"
echo "  Disk: $DISK"
echo "  Boot: $BOOT_TYPE"
echo "  FS root: $FS_TYPE"
echo "  Root size: ${ROOT_GB}GB, Swap: remaining space"
echo "  Hostname: $HOSTNAME, User: $USERNAME"
echo "  GPU: $GPU"
confirm "Continue with these values?" || bail "Cancelled by user"

# --- Partitioning ---
echo ">> Partitioning $DISK ..."
if [[ "$BOOT_TYPE" == "uefi" ]]; then
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart EFI fat32 1MiB 1025MiB
  parted -s "$DISK" set 1 esp on
  start_root=1025MiB
  end_root=$((1025 + ROOT_GB*1024))MiB
  parted -s "$DISK" mkpart ROOT "$FS_TYPE" "$start_root" "$end_root"
  # Use 100% to fill remaining space (avoids overflow when disk is fully allocated)
  parted -s "$DISK" mkpart SWAP linux-swap "$end_root" 100%
  if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
    PEFI="${DISK}p1"; PROOT="${DISK}p2"; PSWAP="${DISK}p3"
  else
    PEFI="${DISK}1"; PROOT="${DISK}2"; PSWAP="${DISK}3"
  fi
else
  parted -s "$DISK" mklabel msdos
  start_root=1MiB
  end_root=$((1 + ROOT_GB*1024))MiB
  parted -s "$DISK" mkpart primary "$FS_TYPE" "$start_root" "$end_root"
  # Use 100% to fill remaining space (avoids overflow when disk is fully allocated)
  parted -s "$DISK" mkpart primary linux-swap "$end_root" 100%
  if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
    PROOT="${DISK}p1"; PSWAP="${DISK}p2"
  else
    PROOT="${DISK}1"; PSWAP="${DISK}2"
  fi
fi

# --- Formatting ---
echo ">> Formatting filesystems ..."
# Create mount directory before formatting (required for btrfs)
mkdir -p /mnt/gentoo

if [[ "$FS_TYPE" == "ext4" ]]; then
  mkfs.ext4 -F "$PROOT"
else
  mkfs.btrfs -f "$PROOT"
  # Mount temporarily to create subvolumes
  mount "$PROOT" /mnt/gentoo || bail "Error mounting $PROOT on /mnt/gentoo to create subvolumes"
  for sub in @ @home @var @tmp @snapshots; do
    btrfs subvolume create /mnt/gentoo/$sub || echo "Warning: error creating subvolume $sub"
  done
  umount /mnt/gentoo || echo "Warning: error unmounting /mnt/gentoo"
fi

mkswap "$PSWAP"
swapon "$PSWAP"

if [[ "$BOOT_TYPE" == "uefi" ]]; then
  mkfs.vfat -F32 "$PEFI"
fi

# --- Mount target ---
# Ensure directory exists (should already exist, but just in case)
mkdir -p /mnt/gentoo

if [[ "$FS_TYPE" == "ext4" ]]; then
  mount "$PROOT" /mnt/gentoo || bail "Error mounting $PROOT on /mnt/gentoo"
else
  # Mount root subvolume
  mount -o subvol=@,compress=zstd "$PROOT" /mnt/gentoo || bail "Error mounting subvolume @ from $PROOT on /mnt/gentoo"
  # Create directories for other subvolumes
  mkdir -p /mnt/gentoo/{home,var,tmp,.snapshots}
  # Mount other subvolumes
  mount -o subvol=@home,compress=zstd "$PROOT" /mnt/gentoo/home || echo "Warning: error mounting @home"
  mount -o subvol=@var,compress=zstd "$PROOT" /mnt/gentoo/var || echo "Warning: error mounting @var"
  mount -o subvol=@tmp,compress=zstd "$PROOT" /mnt/gentoo/tmp || echo "Warning: error mounting @tmp"
  mount -o subvol=@snapshots,compress=zstd "$PROOT" /mnt/gentoo/.snapshots || echo "Warning: error mounting @snapshots"
fi

if [[ "$BOOT_TYPE" == "uefi" ]]; then
  mkdir -p /mnt/gentoo/boot
  mount "$PEFI" /mnt/gentoo/boot
fi

# --- Download Stage3 OpenRC ---
echo ">> Downloading Stage3 OpenRC (amd64) ..."
STAGE_URL_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"

STAGE_TARBALL=$(curl -fsSL "$STAGE_URL_BASE/latest-stage3-amd64-openrc.txt" |
    awk '/^stage3-amd64-openrc-.*\.tar\.xz/ {print $1; exit}')

[[ -n "$STAGE_TARBALL" ]] || bail "Stage3 not found in $STAGE_URL_BASE"

echo ">> Stage3: $STAGE_TARBALL"

wget -O "/mnt/gentoo/$STAGE_TARBALL" \
    "$STAGE_URL_BASE/$STAGE_TARBALL" ||
    bail "Failed to download Stage3"

tar xpf "/mnt/gentoo/$STAGE_TARBALL" \
    -C /mnt/gentoo \
    --xattrs-include='*' \
    --numeric-owner ||
    bail "Failed to extract Stage3"

# --- Prepare chroot ---
cp -L /etc/resolv.conf /mnt/gentoo/etc/
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys; mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev; mount --make-rslave /mnt/gentoo/dev

# --- Get UUIDs before chroot ---
ROOT_UUID=$(blkid -s UUID -o value "$PROOT" 2>/dev/null || echo "")
SWAP_UUID=$(blkid -s UUID -o value "$PSWAP" 2>/dev/null || echo "")
EFI_UUID=""
[[ "$BOOT_TYPE" == "uefi" ]] && EFI_UUID=$(blkid -s UUID -o value "$PEFI" 2>/dev/null || echo "")

# --- Pass variables to chroot ---
echo "$BOOT_TYPE" > /mnt/gentoo/boot_type
echo "$HOSTNAME" > /mnt/gentoo/hostname
echo "$USERNAME" > /mnt/gentoo/username
echo "$ROOT_PASS" > /mnt/gentoo/root_pass
echo "$USER_PASS" > /mnt/gentoo/user_pass
echo "$GPU" > /mnt/gentoo/gpu_choice
echo "$FS_TYPE" > /mnt/gentoo/fs_type
echo "$PROOT" > /mnt/gentoo/root_dev
echo "$PSWAP" > /mnt/gentoo/swap_dev
echo "$ROOT_UUID" > /mnt/gentoo/root_uuid
echo "$SWAP_UUID" > /mnt/gentoo/swap_uuid
[[ "$BOOT_TYPE" == "uefi" ]] && echo "$PEFI" > /mnt/gentoo/efi_dev && echo "$EFI_UUID" > /mnt/gentoo/efi_uuid || true
echo "$DISK" > /mnt/gentoo/disk_dev

# --- Script that will run inside chroot ---
cat > /mnt/gentoo/root/install_in_chroot.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Function to verify kernel/initramfs (simplified for gentoo-kernel-bin)
verify_and_fix_kernel() {
  local FS_TYPE="$1"
  local EFI_DEV="${2:-}"
  
  # Ensure /boot is mounted
  if [[ -n "$EFI_DEV" && -b "$EFI_DEV" ]]; then
    if ! mountpoint -q /boot; then
      mount "$EFI_DEV" /boot || return 1
    fi
  fi
  
  # Verify kernel
  if ls /boot/vmlinuz* >/dev/null 2>&1; then
    echo "✓ Kernel found: $(ls /boot/vmlinuz* | head -n1)"
  else
    echo "ERROR: Kernel not found in /boot"
    echo "gentoo-kernel-bin should have installed the kernel. Check the installation."
    return 1
  fi
  
  # Verify initramfs
  if ls /boot/initramfs* >/dev/null 2>&1; then
    echo "✓ Initramfs found: $(ls /boot/initramfs* | head -n1)"
  else
    echo "ERROR: Initramfs not found in /boot"
    echo "gentoo-kernel-bin should have installed the initramfs. Check the installation."
    return 1
  fi
  
  echo "✓ Kernel and initramfs verified correctly"
  return 0
}

# Function to verify and fix GRUB automatically
verify_and_fix_grub() {
  local BOOT_TYPE="$1"
  local ROOT_UUID="$2"
  local ROOT_DEV="$3"
  local FS_TYPE="$4"
  local DISK_DEV="$5"
  local EFI_DEV="${6:-}"
  local max_attempts=3
  local attempt=1
  
  # Ensure /boot is mounted
  if [[ -n "$EFI_DEV" && -b "$EFI_DEV" ]]; then
    if ! mountpoint -q /boot; then
      mount "$EFI_DEV" /boot || return 1
    fi
  fi
  
  while [[ $attempt -le $max_attempts ]]; do
    # Verify that GRUB is installed
    if ! command -v grub-install >/dev/null 2>&1 || ! command -v grub-mkconfig >/dev/null 2>&1; then
      echo "Attempt $attempt/$max_attempts: GRUB not found, installing..."
      if [[ "$BOOT_TYPE" == "uefi" ]]; then
        emerge --ask=n --autounmask-write=y --autounmask-continue=y --backtrack=300 sys-boot/grub sys-boot/efibootmgr || {
          attempt=$((attempt + 1))
          continue
        }
      else
        emerge --ask=n --autounmask-write=y --autounmask-continue=y --backtrack=300 sys-boot/grub || {
          attempt=$((attempt + 1))
          continue
        }
      fi
    fi
    
    # Install GRUB on the disk
    if [[ "$BOOT_TYPE" == "uefi" ]]; then
      if ! mountpoint -q /boot && [[ -n "$EFI_DEV" && -b "$EFI_DEV" ]]; then
        mount "$EFI_DEV" /boot || return 1
      fi
      grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --recheck || {
        echo "Error in grub-install, retrying..."
        attempt=$((attempt + 1))
        continue
      }
    else
      if [[ -b "$DISK_DEV" ]]; then
        grub-install --target=i386-pc "$DISK_DEV" || {
          echo "Error in grub-install, retrying..."
          attempt=$((attempt + 1))
          continue
        }
      else
        echo "ERROR: Invalid DISK_DEV: $DISK_DEV"
        return 1
      fi
    fi
    
    # Configure GRUB
    mkdir -p /etc/default
    if [[ -n "$ROOT_UUID" ]]; then
      if ! grep -q "GRUB_USE_LINUX_UUID" /etc/default/grub 2>/dev/null; then
        echo 'GRUB_USE_LINUX_UUID=true' >> /etc/default/grub
      fi
      local ROOT_PARAM="root=UUID=$ROOT_UUID"
      if [[ "$FS_TYPE" == "btrfs" ]]; then
        ROOT_PARAM="$ROOT_PARAM rootflags=subvol=@"
      fi
      if ! grep -q "root=" /etc/default/grub 2>/dev/null; then
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$ROOT_PARAM quiet\"" >> /etc/default/grub
      fi
    fi
    
    # Generate grub.cfg
    grub-mkconfig -o /boot/grub/grub.cfg || {
      echo "Error generating grub.cfg, retrying..."
      attempt=$((attempt + 1))
      continue
    }
    
    # Verify that grub.cfg exists and has content
    if [[ -f /boot/grub/grub.cfg ]] && grep -q "menuentry" /boot/grub/grub.cfg 2>/dev/null; then
      echo "✓ GRUB configured correctly"
      return 0
    else
      echo "Invalid grub.cfg, retrying..."
      attempt=$((attempt + 1))
      continue
    fi
  done
  
  echo "ERROR: Could not configure GRUB after $max_attempts attempts"
  return 1
}

BOOT_TYPE=$(cat /boot_type)
HOSTNAME=$(cat /hostname)
USERNAME=$(cat /username)
ROOT_PASS=$(cat /root_pass)
USER_PASS=$(cat /user_pass)
GPU=$(cat /gpu_choice)
FS_TYPE=$(cat /fs_type)
ROOT_DEV=$(cat /root_dev)
SWAP_DEV=$(cat /swap_dev)
DISK_DEV=$(cat /disk_dev)
ROOT_UUID=$(cat /root_uuid)
SWAP_UUID=$(cat /swap_uuid)
EFI_DEV=""
EFI_UUID=""
[[ -f /efi_dev ]] && EFI_DEV=$(cat /efi_dev) || true
[[ -f /efi_uuid ]] && EFI_UUID=$(cat /efi_uuid) || true

# Console and timezone
echo 'KEYMAP="us"' > /etc/conf.d/keymaps
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
# Configure hwclock correctly (OpenRC format)
mkdir -p /etc/conf.d
cat > /etc/conf.d/hwclock <<'HWCLOCK_EOF'
# Hardware clock configuration
clock="UTC"
HWCLOCK_EOF

# Sync Portage
if command -v emerge-webrsync >/dev/null 2>&1; then
  emerge-webrsync || emerge --sync || true
else
  emerge --sync || true
fi

# Read news if eselect is available
if command -v eselect >/dev/null 2>&1; then
  eselect news read --quiet || true
fi

# Profile
if command -v eselect >/dev/null 2>&1; then
  if eselect profile set default/linux/amd64/23.0/desktop/plasma 2>/dev/null; then
    echo "✓ Profile set to desktop/plasma"
  else
    echo "WARNING: desktop/plasma profile not available, using desktop"
    eselect profile set default/linux/amd64/23.0/desktop || true
  fi
fi

# Sync Portage again after changing profile
emerge --sync || true

# make.conf
COMMON_FLAGS="-O2 -pipe -march=native"
NP=$(nproc 2>/dev/null || echo 1)
mkdir -p /etc/portage
cat > /etc/portage/make.conf <<EOF
COMMON_FLAGS="${COMMON_FLAGS}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${NP}"
CHOST="x86_64-pc-linux-gnu"
RUSTFLAGS="-C target-cpu=native"
VIDEO_CARDS="${GPU}"
USE="X wayland kde plasma sddm pipewire pulseaudio udev elogind dbus policykit bluetooth networkmanager opengl vulkan -systemd qt6 qt5"
LINGUAS="en"
ACCEPT_LICENSE="*"
FEATURES="parallel-install"
INPUT_DEVICES="libinput synaptics evdev"
EOF

# Hostname y hosts
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost
EOF

# Locales
cat > /etc/locale.gen <<'LOCALES'
en_US.UTF-8 UTF-8
C.UTF-8 UTF-8
LOCALES

locale-gen || true
if command -v eselect >/dev/null 2>&1; then
  eselect locale set en_US.UTF-8 || eselect locale set en_US.utf8 || true
else
  echo 'LANG="en_US.UTF-8"' > /etc/locale.conf || true
  export LANG="en_US.UTF-8"
fi

# Create portage rules
mkdir -p /etc/portage/package.use /etc/portage/package.accept_keywords /etc/portage/package.mask /etc/portage/env

# More robust configuration for KDE and Qt
cat > /etc/portage/package.use/kde-common <<'EOF'
# KDE Frameworks
kde-frameworks/kio -kwallet
kde-frameworks/kwallet-runtime -keyring -legacy-kwallet
kde-frameworks/kwallet -keyring -legacy-kwallet

# Qt
dev-qt/qtbase -systemd sql sqlite
dev-qt/qtdeclarative -systemd
dev-qt/qttools -systemd
dev-qt/qt5compat -systemd

# Resolve dependency cycles
media-libs/tiff -webp
media-libs/libwebp -tiff

# Break cycle docutils -> pillow -> harfbuzz -> glib -> docutils
dev-python/pillow -truetype
EOF

# Accept keywords for stable but necessary packages
cat > /etc/portage/package.accept_keywords/kde-stable <<'EOF'
# Accept stable KDE and Qt packages (including ~amd64 for dependencies)
# Main Qt packages
dev-qt/qtbase ~amd64
dev-qt/qtdeclarative ~amd64
dev-qt/qttools ~amd64
dev-qt/qt5compat ~amd64
dev-qt/qtsvg ~amd64
dev-qt/qtshadertools ~amd64

# Accept all Qt dependencies (to avoid issues with new versions)
dev-qt/* ~amd64

# KDE
kde-frameworks/* ~amd64
kde-plasma/* ~amd64
EOF

# Sync Portage after configuring keywords to ensure they are applied
echo ">> Syncing Portage after configuring keywords..."
emerge --sync || true

# ============================================================
# PHASE 1: INSTALL AND VERIFY KERNEL + GRUB
# ============================================================
echo ""
echo "=========================================="
echo "PHASE 1: Installing Kernel and GRUB"
echo "=========================================="
echo "This must be completed BEFORE installing applications"
echo ""

# --- Kernel, initramfs and GRUB (improved and automatic) ---
# Mount /boot if EFI_DEV was detected
if [[ -n "${EFI_DEV:-}" && -b "$EFI_DEV" ]]; then
  mkdir -p /boot
  if ! mountpoint -q /boot; then
    mount "$EFI_DEV" /boot || echo "Warning: could not mount $EFI_DEV on /boot"
  fi
fi

# Mount efivarfs on UEFI
if [[ "${BOOT_TYPE:-}" == "uefi" ]]; then
  mkdir -p /sys/firmware/efi/efivars
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
fi

# Install firmware if available
if emerge --search sys-kernel/linux-firmware >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y sys-kernel/linux-firmware || true
fi

# Install precompiled kernel (gentoo-kernel-bin)
echo ">> Installing precompiled kernel (gentoo-kernel-bin)..."
KERNEL_INSTALLED=false
if emerge --search sys-kernel/gentoo-kernel-bin >/dev/null 2>&1; then
  if emerge --ask=n --autounmask-write=y --autounmask-continue=y sys-kernel/gentoo-kernel-bin; then
    echo "✓ gentoo-kernel-bin installed correctly"
    KERNEL_INSTALLED=true
  else
    echo "Error installing gentoo-kernel-bin"
    KERNEL_INSTALLED=false
  fi
else
  echo "WARNING: sys-kernel/gentoo-kernel-bin is not available in the repository"
  KERNEL_INSTALLED=false
fi

# Generate /etc/fstab BEFORE verifying (necessary for boot)
# Always regenerate fstab to ensure it's correct (even if it exists empty)
echo ">> Generating /etc/fstab..."
# UUIDs were already obtained before chroot

# Create fstab from scratch
cat > /etc/fstab <<EOF
# <fs>      <mountpoint>  <type>  <opts>              <dump/pass>
EOF

# Add entries according to filesystem type
if [[ "$FS_TYPE" == "btrfs" ]]; then
  if [[ -n "$ROOT_UUID" ]]; then
    echo "UUID=$ROOT_UUID  /              btrfs  subvol=@,compress=zstd,noatime  0 1" >> /etc/fstab
    echo "UUID=$ROOT_UUID  /home          btrfs  subvol=@home,compress=zstd,noatime  0 2" >> /etc/fstab
    echo "UUID=$ROOT_UUID  /var           btrfs  subvol=@var,compress=zstd,noatime  0 2" >> /etc/fstab
    echo "UUID=$ROOT_UUID  /tmp           btrfs  subvol=@tmp,compress=zstd,noatime  0 2" >> /etc/fstab
    echo "UUID=$ROOT_UUID  /.snapshots    btrfs  subvol=@snapshots,compress=zstd,noatime  0 2" >> /etc/fstab
  else
    echo "$ROOT_DEV  /              btrfs  subvol=@,compress=zstd,noatime  0 1" >> /etc/fstab
    echo "$ROOT_DEV  /home          btrfs  subvol=@home,compress=zstd,noatime  0 2" >> /etc/fstab
    echo "$ROOT_DEV  /var           btrfs  subvol=@var,compress=zstd,noatime  0 2" >> /etc/fstab
    echo "$ROOT_DEV  /tmp           btrfs  subvol=@tmp,compress=zstd,noatime  0 2" >> /etc/fstab
    echo "$ROOT_DEV  /.snapshots    btrfs  subvol=@snapshots,compress=zstd,noatime  0 2" >> /etc/fstab
  fi
else
  if [[ -n "$ROOT_UUID" ]]; then
    echo "UUID=$ROOT_UUID  /              ext4   noatime  0 1" >> /etc/fstab
  else
    echo "$ROOT_DEV  /              ext4   noatime  0 1" >> /etc/fstab
  fi
fi

# Add EFI partition if UEFI
if [[ -n "${EFI_UUID:-}" && "$BOOT_TYPE" == "uefi" ]]; then
  if [[ -n "$EFI_UUID" ]]; then
    echo "UUID=$EFI_UUID  /boot          vfat   defaults,noatime  0 2" >> /etc/fstab
  else
    echo "$EFI_DEV  /boot          vfat   defaults,noatime  0 2" >> /etc/fstab
  fi
fi

# Add swap
if [[ -n "$SWAP_UUID" ]]; then
  echo "UUID=$SWAP_UUID  none           swap   sw  0 0" >> /etc/fstab
else
  echo "$SWAP_DEV  none           swap   sw  0 0" >> /etc/fstab
fi

# Verify that fstab was generated correctly
if [[ -f /etc/fstab ]] && [[ -s /etc/fstab ]] && grep -q -v "^#" /etc/fstab; then
  echo "✓ /etc/fstab generated correctly"
  echo "Contents of /etc/fstab:"
  cat /etc/fstab
else
  echo "ERROR: /etc/fstab is empty or was not generated correctly"
  echo "This will cause problems when booting the system"
fi

# Verify and fix kernel/initramfs automatically
echo ">> Verifying kernel and initramfs (with automatic correction)..."
if ! verify_and_fix_kernel "$FS_TYPE" "${EFI_DEV:-}"; then
  echo ""
  echo "=========================================="
  echo "CRITICAL ERROR: Could not verify/fix kernel"
  echo "=========================================="
  echo "The system will NOT boot. Check the errors above."
  exit 1
fi

# Install base dependencies for GRUB (minimal)
echo ">> Installing minimal dependencies for GRUB..."
BASE_DEPS="dev-python/pillow dev-python/docutils dev-libs/glib media-libs/harfbuzz"
for p in $BASE_DEPS; do
  if emerge --search "$p" >/dev/null 2>&1; then
    emerge --ask=n --autounmask-write=y --autounmask-continue=y --backtrack=300 "$p" || echo "Warning: could not install $p"
  fi
done

# Verify and fix GRUB automatically
echo ">> Installing and configuring GRUB (with automatic correction)..."
if ! verify_and_fix_grub "$BOOT_TYPE" "$ROOT_UUID" "$ROOT_DEV" "$FS_TYPE" "$DISK_DEV" "${EFI_DEV:-}"; then
  echo ""
  echo "=========================================="
  echo "CRITICAL ERROR: Could not verify/fix GRUB"
  echo "=========================================="
  echo "The system will NOT boot. Check the errors above."
  exit 1
fi

# Final critical verification of boot system
echo ""
echo ">> Final boot system verification..."
BOOT_OK=true

if ! ls /boot/vmlinuz* >/dev/null 2>&1; then
  echo "ERROR: Kernel not found"
  BOOT_OK=false
else
  echo "✓ Kernel: $(ls /boot/vmlinuz* | head -n1)"
fi

if ! ls /boot/initramfs* >/dev/null 2>&1; then
  echo "ERROR: Initramfs not found"
  BOOT_OK=false
else
  echo "✓ Initramfs: $(ls /boot/initramfs* | head -n1)"
fi

if [[ ! -f /boot/grub/grub.cfg ]]; then
  echo "ERROR: grub.cfg not found"
  BOOT_OK=false
else
  echo "✓ GRUB config: /boot/grub/grub.cfg"
fi

if [[ ! -f /etc/fstab ]]; then
  echo "ERROR: fstab not found"
  BOOT_OK=false
else
  echo "✓ fstab: /etc/fstab"
fi

if [[ ! -f /sbin/init ]]; then
  echo "ERROR: /sbin/init not found"
  BOOT_OK=false
else
  echo "✓ Init: $(ls -la /sbin/init | awk '{print $9, $10, $11}')"
fi

if [[ "$BOOT_OK" == "false" ]]; then
  echo ""
  echo "=========================================="
  echo "CRITICAL ERROR: Incomplete boot system"
  echo "=========================================="
  echo "DO NOT CONTINUE with application installation."
  echo "The system will NOT boot correctly."
  exit 1
fi

echo ""
echo "=========================================="
echo "✓ PHASE 1 COMPLETED: Kernel and GRUB ready"
echo "=========================================="
echo ""

# ============================================================
# PHASE 2: INSTALL APPLICATIONS (KDE, etc.)
# ============================================================
echo ""
echo "=========================================="
echo "PHASE 2: Installing applications (KDE, etc.)"
echo "=========================================="
echo ""

# Install base dependencies before KDE
echo ">> Installing base dependencies (X11, Wayland, etc)..."
BASE_PKGS="x11-base/xorg-server x11-apps/xinit x11-libs/libX11 media-libs/mesa app-admin/sudo sys-apps/dbus"
for p in $BASE_PKGS; do
  if emerge --search "$p" >/dev/null 2>&1; then
    emerge --ask=n --autounmask-write=y --autounmask-continue=y --backtrack=300 --quiet-build=y "$p" || true
  fi
done

# Ensure cycle dependencies are installed correctly
echo ">> Verifying critical dependencies to break cycles..."
CRITICAL_DEPS="dev-python/pillow dev-python/docutils dev-libs/glib"
for p in $CRITICAL_DEPS; do
  if emerge --search "$p" >/dev/null 2>&1; then
    emerge --ask=n --autounmask-write=y --autounmask-continue=y --backtrack=300 "$p" || echo "Warning: problem with $p"
  fi
done

# Configure OpenRC and critical services
echo ">> Configuring OpenRC and critical services..."

# Ensure OpenRC is installed
if ! command -v rc-update >/dev/null 2>&1; then
  echo "OpenRC not found, installing..."
  emerge --ask=n --autounmask-write=y --autounmask-continue=y sys-apps/openrc || true
fi

# Enable critical services for boot
CRITICAL_SERVICES="sysinit boot default"
for svc in $CRITICAL_SERVICES; do
  if [[ -f /etc/init.d/$svc ]]; then
    rc-update add $svc boot || true
  fi
done

# Enable base services
if [[ -f /etc/init.d/dbus ]]; then
  rc-update add dbus default || true
fi

# Enable network services
if [[ -f /etc/init.d/NetworkManager ]]; then
  rc-update add NetworkManager default || true
elif [[ -f /etc/init.d/dhcpcd ]]; then
  rc-update add dhcpcd default || true
fi

# Enable hardware services
if [[ -f /etc/init.d/udev ]]; then
  rc-update add udev sysinit || true
fi
if [[ -f /etc/init.d/udev-trigger ]]; then
  rc-update add udev-trigger sysinit || true
fi

# Verify that the system can boot
echo ">> Verifying boot configuration..."
if [[ ! -f /sbin/init ]]; then
  echo "WARNING: /sbin/init not found. The system may not boot."
  if [[ -f /usr/bin/openrc-init ]]; then
    ln -sf /usr/bin/openrc-init /sbin/init || true
  fi
fi

# Update world
echo ">> Updating @world..."
emerge --ask=n --autounmask-write=y --autounmask-continue=y --update --deep --newuse @world || true

# Define emerge options for later use
BACKTRACK_OPTS="--backtrack=300 --autounmask-write=y --autounmask-continue=y"
EMERGE_OPTS="--ask=n ${BACKTRACK_OPTS} --quiet-build=y"

# Install useful system tools (before KDE)
echo ">> Installing fastfetch and htop..."
if emerge --search app-misc/fastfetch >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} app-misc/fastfetch || echo "Error installing fastfetch"
else
  # Try with another name if it exists
  if emerge --search fastfetch >/dev/null 2>&1; then
    PKG=$(emerge --search fastfetch | awk '/^[a-z0-9-]+\/[a-z0-9-]+/ {print $1; exit}')
    [[ -n "$PKG" ]] && emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} "$PKG" || echo "Error installing fastfetch"
  fi
fi

if emerge --search sys-process/htop >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} sys-process/htop || echo "Error installing htop"
fi

# Install btrfs tools only if filesystem is btrfs
if [[ "$FS_TYPE" == "btrfs" ]]; then
  echo ">> Installing sys-fs/btrfs-progs (required for btrfs)..."
  if emerge --search sys-fs/btrfs-progs >/dev/null 2>&1; then
    emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} sys-fs/btrfs-progs || echo "Error installing btrfs-progs"
  fi
  
  echo ">> Installing sys-fs/btrfsmaintenance (maintenance tools for btrfs)..."
  if emerge --search sys-fs/btrfsmaintenance >/dev/null 2>&1; then
    emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} sys-fs/btrfsmaintenance || echo "Error installing btrfsmaintenance"
  fi
fi

# Improved staged installation: Qt -> frameworks -> plasma
echo ">> Installing Qt and dependencies..."

# Install complete Qt first
QT_PKGS="dev-qt/qtbase dev-qt/qtdeclarative dev-qt/qttools dev-qt/qt5compat dev-qt/qtsvg dev-qt/qtshadertools"
echo "Installing Qt packages..."
emerge ${EMERGE_OPTS} ${QT_PKGS} || {
  echo "Installing Qt package by package..."
  for p in $QT_PKGS; do
    if emerge --search "$p" >/dev/null 2>&1; then
      emerge ${EMERGE_OPTS} "$p" || echo "Error installing $p"
    fi
  done
}

# Install base frameworks
echo ">> Installing KDE Frameworks base..."
KF_BASE="kde-frameworks/kf-env kde-frameworks/kcoreaddons kde-frameworks/karchive kde-frameworks/ki18n kde-frameworks/kconfig kde-frameworks/kwidgetsaddons"
emerge ${EMERGE_OPTS} ${KF_BASE} || {
  echo "Installing frameworks one by one..."
  for p in $KF_BASE; do
    if emerge --search "$p" >/dev/null 2>&1; then
      emerge ${EMERGE_OPTS} "$p" || echo "Error installing $p"
    fi
  done
}

# Install kio (critical for KDE)
echo ">> Installing kde-frameworks/kio..."
if emerge --search kde-frameworks/kio >/dev/null 2>&1; then
  emerge ${EMERGE_OPTS} kde-frameworks/kio || echo "Error installing kio"
fi

# Install SDDM and configure it to run on boot
echo ">> Installing and configuring SDDM..."
if emerge --search x11-misc/sddm >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y x11-misc/sddm || echo "Error installing sddm"
  
  # Install display-manager-init (creates /etc/conf.d/display-manager and /etc/init.d/display-manager automatically)
  echo ">> Installing gui-libs/display-manager-init..."
  if emerge --search gui-libs/display-manager-init >/dev/null 2>&1; then
    emerge --ask=n --autounmask-write=y --autounmask-continue=y gui-libs/display-manager-init || echo "Warning: could not install display-manager-init"
  fi
  
  # Configure display-manager so SDDM starts automatically
  echo ">> Configuring display-manager for SDDM..."
  if [[ -f /etc/init.d/display-manager ]]; then
    rc-update add display-manager default || true
    echo "✓ display-manager enabled in default runlevel"
  else
    echo "WARNING: /etc/init.d/display-manager not found. Make sure gui-libs/display-manager-init is installed."
  fi
  
  # Edit /etc/conf.d/display-manager to set SDDM (file is created automatically by display-manager-init)
  echo ">> Configuring /etc/conf.d/display-manager..."
  mkdir -p /etc/conf.d
  if [[ -f /etc/conf.d/display-manager ]]; then
    # Edit DISPLAYMANAGER value if it exists, or add it if it doesn't
    if grep -q "^DISPLAYMANAGER=" /etc/conf.d/display-manager 2>/dev/null; then
      sed -i 's/^DISPLAYMANAGER=.*/DISPLAYMANAGER="sddm"/' /etc/conf.d/display-manager
    else
      echo 'DISPLAYMANAGER="sddm"' >> /etc/conf.d/display-manager
    fi
    echo "✓ DISPLAYMANAGER configured as \"sddm\" in /etc/conf.d/display-manager"
  else
    # If file doesn't exist, create it (in case display-manager-init didn't create it)
    cat > /etc/conf.d/display-manager <<'DISPLAYMANAGER_EOF'
CHECKVT=7
DISPLAYMANAGER="sddm"
DISPLAYMANAGER_EOF
    echo "✓ File /etc/conf.d/display-manager created with DISPLAYMANAGER=\"sddm\""
  fi
  
  # Ensure SDDM configuration directory exists
  mkdir -p /etc/sddm.conf.d
  
  # Verify that SDDM is installed
  if command -v sddm >/dev/null 2>&1; then
    echo "✓ SDDM installed and configured to start automatically"
  fi
fi

# Install plasma-meta (complete)
echo ">> Installing kde-plasma/plasma-meta..."
if emerge --search kde-plasma/plasma-meta >/dev/null 2>&1; then
  emerge ${EMERGE_OPTS} kde-plasma/plasma-meta || echo "Error installing plasma-meta"
fi

# Install kdesu-gui (graphical interface for sudo)
echo ">> Installing kde-plasma/kdesu-gui..."
if emerge --search kde-plasma/kdesu-gui >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} kde-plasma/kdesu-gui || echo "Error installing kdesu-gui"
fi

# Install only konsole (KDE terminal)
echo ">> Installing kde-apps/konsole..."
if emerge --search kde-apps/konsole >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} kde-apps/konsole || echo "Error installing konsole"
fi

# Install dolphin (KDE file manager)
echo ">> Installing kde-apps/dolphin..."
if emerge --search kde-apps/dolphin >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} kde-apps/dolphin || echo "Error installing dolphin"
fi

# Install kwrite (KDE text editor)
echo ">> Installing kde-apps/kwrite..."
if emerge --search kde-apps/kwrite >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} kde-apps/kwrite || echo "Error installing kwrite"
fi

# Install firefox-bin (web browser)
echo ">> Installing www-client/firefox-bin..."
if emerge --search www-client/firefox-bin >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} www-client/firefox-bin || echo "Error installing firefox-bin"
fi

# Install partitionmanager (partition management tool)
echo ">> Installing sys-block/partitionmanager..."
if emerge --search sys-block/partitionmanager >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y ${BACKTRACK_OPTS} sys-block/partitionmanager || echo "Error installing partitionmanager"
fi

# Try to resolve remaining cycles
echo ">> Resolving remaining dependencies..."
emerge ${EMERGE_OPTS} media-libs/libwebp media-libs/tiff || true

# NVIDIA config if applicable (for X11)
if [[ "$GPU" == "nvidia" ]]; then
  sed -i 's/^VIDEO_CARDS=.*/VIDEO_CARDS="nvidia"/' /etc/portage/make.conf || true
  if emerge --search x11-drivers/nvidia-drivers >/dev/null 2>&1; then
    emerge --ask=n --autounmask-write=y --autounmask-continue=y x11-drivers/nvidia-drivers || true
  fi
  # Blacklist nouveau (required for NVIDIA)
  mkdir -p /etc/modprobe.d /etc/X11/xorg.conf.d
  echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
  echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist-nouveau.conf
  # Create X11 configuration for NVIDIA
  cat > /etc/X11/xorg.conf.d/10-nvidia.conf <<EOF
Section "Device"
  Identifier "Nvidia Card"
  Driver "nvidia"
EndSection
EOF
  echo "✓ X11 configuration for NVIDIA created"
fi

# Enable NetworkManager
if [[ -f /etc/init.d/NetworkManager ]]; then
  rc-update add NetworkManager default || true
fi

# Create groups and user
for g in plugdev network; do
  if ! getent group "$g" >/dev/null 2>&1; then
    groupadd "$g" || true
  fi
done

if ! id -u "$USERNAME" >/dev/null 2>&1; then
  useradd -m -G wheel,video,audio,plugdev,lp,network -s /bin/bash "$USERNAME" || true
fi

# Set passwords
if echo "${USERNAME}:${USER_PASS}" | chpasswd 2>/tmp/chpasswd.err; then
  echo "Password set for ${USERNAME}."
else
  echo "chpasswd failed: $(cat /tmp/chpasswd.err || true)"
  echo "Trying interactive passwd for ${USERNAME}..."
  passwd "$USERNAME" || true
fi

if echo "root:${ROOT_PASS}" | chpasswd 2>/tmp/chpasswd_root.err; then
  echo "Root password set."
else
  echo "chpasswd root failed: $(cat /tmp/chpasswd_root.err || true)"
  passwd root || true
fi

# Enable sudo for wheel if commented
if grep -q "^# %wheel" /etc/sudoers 2>/dev/null; then
  sed -i 's/^# %wheel/%wheel/' /etc/sudoers || true
fi

# Clean temporary files with passwords
rm -f /boot_type /hostname /username /root_pass /user_pass /gpu_choice /fs_type /root_dev /swap_dev /efi_dev /disk_dev /root_uuid /swap_uuid /efi_uuid 2>/dev/null || true

# Final system verification (with /boot mounted)
echo ">> Final system verification..."
echo "Ensuring /boot is mounted..."
if [[ -n "${EFI_DEV:-}" && -b "$EFI_DEV" ]]; then
  if ! mountpoint -q /boot; then
    mount "$EFI_DEV" /boot || echo "Warning: could not mount /boot"
  fi
fi

KERNEL_FILE=$(ls /boot/vmlinuz* 2>/dev/null | head -n1 || echo "")
INITRAMFS_FILE=$(ls /boot/initramfs* 2>/dev/null | head -n1 || echo "")
GRUB_FILE=$(ls /boot/grub/grub.cfg 2>/dev/null || echo "")
FSTAB_FILE=$(ls /etc/fstab 2>/dev/null || echo "")
INIT_FILE=$(ls -la /sbin/init 2>/dev/null || echo "")

echo "Kernel: ${KERNEL_FILE:-NOT FOUND}"
echo "Initramfs: ${INITRAMFS_FILE:-NOT FOUND}"
echo "GRUB config: ${GRUB_FILE:-NOT FOUND}"
echo "fstab: ${FSTAB_FILE:-NOT FOUND}"
echo "Init: ${INIT_FILE:-NOT FOUND}"

# Verify critical items and show warnings
CRITICAL_ERRORS=0
if [[ -z "$KERNEL_FILE" ]]; then
  echo "ERROR: Kernel not found - SYSTEM WILL NOT BOOT"
  CRITICAL_ERRORS=$((CRITICAL_ERRORS + 1))
fi
if [[ -z "$INITRAMFS_FILE" ]]; then
  echo "ERROR: Initramfs not found - SYSTEM WILL NOT BOOT"
  CRITICAL_ERRORS=$((CRITICAL_ERRORS + 1))
fi
if [[ -z "$GRUB_FILE" ]]; then
  echo "ERROR: grub.cfg not found - GRUB WILL NOT WORK"
  CRITICAL_ERRORS=$((CRITICAL_ERRORS + 1))
fi
if [[ -z "$FSTAB_FILE" ]]; then
  echo "ERROR: fstab not found - SYSTEM WILL NOT MOUNT PARTITIONS"
  CRITICAL_ERRORS=$((CRITICAL_ERRORS + 1))
fi
if [[ -z "$INIT_FILE" ]]; then
  echo "ERROR: /sbin/init not found - SYSTEM WILL NOT START"
  CRITICAL_ERRORS=$((CRITICAL_ERRORS + 1))
fi

if [[ $CRITICAL_ERRORS -gt 0 ]]; then
  echo ""
  echo "=========================================="
  echo "CRITICAL ERRORS FOUND: $CRITICAL_ERRORS"
  echo "=========================================="
  echo "DO NOT REBOOT until these problems are resolved."
  echo ""
fi

# Verify that root filesystem is correctly configured
echo ""
echo ">> Verifying root filesystem configuration..."
if [[ -n "$ROOT_UUID" ]]; then
  echo "Root UUID: $ROOT_UUID"
  if blkid | grep -q "$ROOT_UUID"; then
    echo "Root filesystem UUID verified correctly."
  else
    echo "WARNING: Root filesystem UUID not found in the system."
  fi
else
  echo "Root device: $ROOT_DEV"
  if [[ -b "$ROOT_DEV" ]]; then
    echo "Root device verified correctly."
  else
    echo "WARNING: Root device not found."
  fi
fi

# Verify that grub.cfg has the correct configuration
if [[ -f /boot/grub/grub.cfg ]]; then
  echo ""
  echo ">> Verifying grub.cfg content..."
  if grep -q "root=UUID=$ROOT_UUID" /boot/grub/grub.cfg 2>/dev/null || grep -q "root=$ROOT_DEV" /boot/grub/grub.cfg 2>/dev/null; then
    echo "Root parameter found correctly in grub.cfg."
  else
    echo "WARNING: Root parameter not found in grub.cfg."
    echo "The system may not boot correctly."
  fi
  
  if [[ "$FS_TYPE" == "btrfs" ]] && grep -q "rootflags=subvol=@" /boot/grub/grub.cfg 2>/dev/null; then
    echo "Rootflags parameter for btrfs found correctly."
  elif [[ "$FS_TYPE" == "btrfs" ]]; then
    echo "WARNING: Rootflags for btrfs not found in grub.cfg."
  fi
fi

# Final verification of enabled services
echo ""
echo ">> Verifying enabled services..."
echo "Services in default runlevel:"
rc-update show default 2>/dev/null | grep -E "(sddm|dbus|NetworkManager|pipewire)" || echo "Some services may not be enabled"

echo ""
echo ">>> Configuration inside chroot completed."
echo ">>> /etc/fstab generated automatically."
echo ""
echo "NOTE: USE flag 'truetype' was temporarily disabled in dev-python/pillow"
echo "      to break a dependency cycle. You can reactivate it later with:"
echo "      echo 'dev-python/pillow truetype' >> /etc/portage/package.use/pillow"
echo "      emerge --ask=n --update --newuse dev-python/pillow"
echo ""
echo "BEFORE REBOOTING, verify:"
echo "  1. /boot/vmlinuz* exists"
echo "  2. /boot/initramfs* exists"
echo "  3. /boot/grub/grub.cfg exists and has correct entries"
echo "  4. /etc/fstab has the correct partitions"
echo "  5. /sbin/init exists and points to openrc-init"
echo "  6. SDDM is enabled: rc-update show | grep sddm"
echo ""
echo "If something is missing, DO NOT REBOOT until you fix it."
CHROOT_EOF

# Execute chroot script
chmod +x /mnt/gentoo/root/install_in_chroot.sh
echo ">> Entering chroot to complete installation (this may take a while)..."
chroot /mnt/gentoo /bin/bash -lc "/root/install_in_chroot.sh"

# Clean stage3 compressed file
echo ">> Cleaning stage3 compressed file..."
if [[ -n "$STAGE_TARBALL" ]] && [[ -f "/mnt/gentoo/$STAGE_TARBALL" ]]; then
  rm -f "/mnt/gentoo/$STAGE_TARBALL"
  echo "✓ Stage3 file removed: $STAGE_TARBALL"
else
  echo "Stage3 file not found or already removed"
fi

# Clean installation script inside chroot
echo ">> Cleaning installation script..."
if [[ -f "/mnt/gentoo/root/install_in_chroot.sh" ]]; then
  rm -f "/mnt/gentoo/root/install_in_chroot.sh"
  echo "✓ Script install_in_chroot.sh removed"
else
  echo "Script install_in_chroot.sh not found or already removed"
fi

echo
echo "=== Installation completed (script). ==="
echo "Before rebooting, review:"
echo "  - /mnt/gentoo/etc/fstab"
echo "  - /mnt/gentoo/etc/portage/make.conf"
echo "  - /mnt/gentoo/boot/grub/grub.cfg"
echo
echo "To exit and reboot:"
echo "  umount -l /mnt/gentoo/dev{/shm,/pts,} || true"
echo "  umount -R /mnt/gentoo"
echo "  swapoff -a"
echo "  reboot"
