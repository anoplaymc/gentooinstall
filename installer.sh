#!/usr/bin/env bash
set -euo pipefail

bail() { echo "ERROR: $*" >&2; exit 1; }
ask() { local prompt="$1"; read -r -p "$prompt" REPLY && echo "$REPLY"; }
confirm() { local ans; read -r -p "$1 [y/N]: " ans; [[ "${ans,,}" == "y" ]]; }

# Minimum tools on the host
for c in parted mkfs.ext4 mkfs.btrfs mkswap swapon wget tar curl lsblk blkid sed awk mount umount chroot sfdisk wipefs; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "Missing tool: $c. Install it in the live environment before continuing."
    bail "Insufficient tools."
  fi
done

[[ $EUID -eq 0 ]] || bail "Run as root from the live environment"

echo "=== Gentoo Installer amd64 OpenRC + KDE + PipeWire (100% Binhost, <30 mins) ==="

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

DISK=$(ask "Target disk (e.g. /dev/sda, /dev/nvme0n1, /dev/vda): ")
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

# --- Wipe & Partitioning ---
echo ">> Wiping and partitioning $DISK ..."
wipefs -a "$DISK"
if [[ "$BOOT_TYPE" == "uefi" ]]; then
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart EFI fat32 1MiB 1025MiB
  parted -s "$DISK" set 1 esp on
  start_root=1025MiB
  end_root=$((1025 + ROOT_GB*1024))MiB
  parted -s "$DISK" mkpart ROOT "$FS_TYPE" "$start_root" "$end_root"
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
  parted -s "$DISK" mkpart primary linux-swap "$end_root" 100%
  if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
    PROOT="${DISK}p1"; PSWAP="${DISK}p2"
  else
    PROOT="${DISK}1"; PSWAP="${DISK}2"
  fi
fi

sleep 2

# --- Formatting ---
echo ">> Formatting filesystems ..."
mkdir -p /mnt/gentoo

if [[ "$FS_TYPE" == "ext4" ]]; then
  mkfs.ext4 -F "$PROOT"
else
  mkfs.btrfs -f "$PROOT"
  mount "$PROOT" /mnt/gentoo || bail "Error mounting $PROOT on /mnt/gentoo"
  for sub in @ @home @var @tmp @snapshots; do
    btrfs subvolume create /mnt/gentoo/$sub || true
  done
  umount /mnt/gentoo || true
fi

mkswap "$PSWAP"
swapon "$PSWAP"

if [[ "$BOOT_TYPE" == "uefi" ]]; then
  mkfs.vfat -F32 "$PEFI"
fi

# --- Mount target ---
mkdir -p /mnt/gentoo

if [[ "$FS_TYPE" == "ext4" ]]; then
  mount "$PROOT" /mnt/gentoo || bail "Error mounting $PROOT on /mnt/gentoo"
else
  mount -o subvol=@,compress=zstd "$PROOT" /mnt/gentoo || bail "Error mounting subvolume @"
  mkdir -p /mnt/gentoo/{home,var,tmp,.snapshots}
  mount -o subvol=@home,compress=zstd "$PROOT" /mnt/gentoo/home || true
  mount -o subvol=@var,compress=zstd "$PROOT" /mnt/gentoo/var || true
  mount -o subvol=@tmp,compress=zstd "$PROOT" /mnt/gentoo/tmp || true
  mount -o subvol=@snapshots,compress=zstd "$PROOT" /mnt/gentoo/.snapshots || true
fi

if [[ "$BOOT_TYPE" == "uefi" ]]; then
  mkdir -p /mnt/gentoo/boot
  mount "$PEFI" /mnt/gentoo/boot
fi

# --- Download Stage3 OpenRC ---
echo ">> Downloading Stage3 OpenRC (amd64) ..."
STAGE_URL_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"
STAGE_TARBALL=$(curl -fsSL "$STAGE_URL_BASE/latest-stage3-amd64-openrc.txt" | awk '/^stage3-amd64-openrc-.*\.tar\.xz/ {print $1; exit}')
[[ -n "$STAGE_TARBALL" ]] || bail "Stage3 not found"

echo ">> Stage3: $STAGE_TARBALL"
wget -O "/mnt/gentoo/$STAGE_TARBALL" "$STAGE_URL_BASE/$STAGE_TARBALL" || bail "Failed to download Stage3"
tar xpf "/mnt/gentoo/$STAGE_TARBALL" -C /mnt/gentoo --xattrs-include='*' --numeric-owner || bail "Failed to extract Stage3"

# --- Prepare chroot ---
cp -L /etc/resolv.conf /mnt/gentoo/etc/
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys; mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev; mount --make-rslave /mnt/gentoo/dev

ROOT_UUID=$(blkid -s UUID -o value "$PROOT" 2>/dev/null || echo "")
SWAP_UUID=$(blkid -s UUID -o value "$PSWAP" 2>/dev/null || echo "")
EFI_UUID=""
[[ "$BOOT_TYPE" == "uefi" ]] && EFI_UUID=$(blkid -s UUID -o value "$PEFI" 2>/dev/null || echo "")

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

# --- Chroot Installation Script ---
cat > /mnt/gentoo/root/install_in_chroot.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail

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

echo "UTC" > /etc/timezone
mkdir -p /etc/conf.d
echo 'clock="UTC"' > /etc/conf.d/hwclock

echo ">> Setting up Binhost configuration for pure binary speed (<30 mins) ..."
mkdir -p /etc/portage
cat > /etc/portage/make.conf <<EOF
COMMON_FLAGS="-O2 -pipe -march=x86-64-v3"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j$(nproc)"
CHOST="x86_64-pc-linux-gnu"
VIDEO_CARDS="${GPU}"
USE="X wayland kde plasma sddm pipewire pulseaudio udev elogind dbus policykit bluetooth networkmanager opengl vulkan -systemd qt6 qt5"
LINGUAS="en"
ACCEPT_LICENSE="*"
FEATURES="getbinpkg parallel-install"
EMERGE_DEFAULT_OPTS="--getbinpkg --autounmask-write --autounmask-continue --backtrack=300"
INPUT_DEVICES="libinput synaptics evdev"
EOF

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost
EOF

cat > /etc/locale.gen <<'LOCALES'
en_US.UTF-8 UTF-8
C.UTF-8 UTF-8
LOCALES
locale-gen || true
eselect locale set en_US.UTF-8 || true

mkdir -p /etc/portage/package.use /etc/portage/package.accept_keywords

cat > /etc/portage/package.accept_keywords/binhost <<'EOF'
*/* ~amd64
EOF

echo ">> Syncing Portage ..."
emerge-webrsync || emerge --sync || true

# Mount /boot if UEFI
if [[ -n "${EFI_DEV:-}" && -b "$EFI_DEV" ]]; then
  mkdir -p /boot
  mountpoint -q /boot || mount "$EFI_DEV" /boot || true
fi
[[ "$BOOT_TYPE" == "uefi" ]] && mkdir -p /sys/firmware/efi/efivars && mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true

echo ">> Installing Kernel, Firmware and GRUB (all from binaries) ..."
emerge sys-kernel/linux-firmware sys-kernel/gentoo-kernel-bin sys-boot/grub || bail "Failed to install base packages"
[[ "$BOOT_TYPE" == "uefi" ]] && emerge sys-boot/efibootmgr || true

# Generate fstab
cat > /etc/fstab <<EOF
# <fs>      <mountpoint>  <type>  <opts>              <dump/pass>
EOF

if [[ "$FS_TYPE" == "btrfs" ]]; then
  [[ -n "$ROOT_UUID" ]] && RSRC="UUID=$ROOT_UUID" || RSRC="$ROOT_DEV"
  echo "$RSRC  /              btrfs  subvol=@,compress=zstd,noatime  0 1" >> /etc/fstab
  echo "$RSRC  /home          btrfs  subvol=@home,compress=zstd,noatime  0 2" >> /etc/fstab
  echo "$RSRC  /var           btrfs  subvol=@var,compress=zstd,noatime  0 2" >> /etc/fstab
  echo "$RSRC  /tmp           btrfs  subvol=@tmp,compress=zstd,noatime  0 2" >> /etc/fstab
  echo "$RSRC  /.snapshots    btrfs  subvol=@snapshots,compress=zstd,noatime  0 2" >> /etc/fstab
else
  [[ -n "$ROOT_UUID" ]] && RSRC="UUID=$ROOT_UUID" || RSRC="$ROOT_DEV"
  echo "$RSRC  /              ext4   noatime  0 1" >> /etc/fstab
fi

if [[ "$BOOT_TYPE" == "uefi" ]]; then
  [[ -n "$EFI_UUID" ]] && ESRC="UUID=$EFI_UUID" || ESRC="$EFI_DEV"
  echo "$ESRC  /boot          vfat   defaults,noatime  0 2" >> /etc/fstab
fi

[[ -n "$SWAP_UUID" ]] && SSRC="UUID=$SWAP_UUID" || SSRC="$SWAP_DEV"
echo "$SSRC  none           swap   sw  0 0" >> /etc/fstab

# Install GRUB
if [[ "$BOOT_TYPE" == "uefi" ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --recheck
else
  grub-install --target=i386-pc "$DISK_DEV"
fi
grub-mkconfig -o /boot/grub/grub.cfg

echo ">> Installing Desktop Environment, SDDM, and Utils ..."
emerge x11-misc/sddm gui-libs/display-manager-init kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin www-client/firefox-bin app-misc/fastfetch sys-process/htop || bail "Failed desktop installation"

# Services setup
rc-update add dbus default || true
rc-update add NetworkManager default || true
rc-update add udev sysinit || true
rc-update add udev-trigger sysinit || true
rc-update add display-manager default || true

mkdir -p /etc/conf.d
echo 'DISPLAYMANAGER="sddm"' > /etc/conf.d/display-manager

# Users setup
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel,audio,video,users,portage -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd

emerge app-admin/sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

echo "=== Gentoo Binary Installation Complete Successfully! ==="
CHROOT_EOF

chmod +x /mnt/gentoo/root/install_in_chroot.sh
chroot /mnt/gentoo /root/install_in_chroot.sh || bail "Chroot script failed"

echo "=== Cleaning up and unmounting ==="
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo || true
swapoff "$PSWAP" || true

echo "============================================================"
echo " SUCCESS! Gentoo OpenRC + KDE installed successfully in <30m."
echo " You can now reboot your system."
echo "============================================================"
