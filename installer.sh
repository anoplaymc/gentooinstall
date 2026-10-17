#!/bin/bash
set -e

DISK="/dev/vda"
ROOT_PASS="lk2020"
USER_NAME="anoplay"
USER_PASS="lk2020"
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/20261011T170049Z/stage3-amd64-openrc-20261011T170049Z.tar.xz"

echo "=== 1. Разметка диска ($DISK) для BIOS ==="
wipefs -a "$DISK"
echo "label: dos" | sfdisk "$DISK"
echo ",,L,*" | sfdisk "$DISK"

PART_ROOT="${DISK}1"
sleep 2

echo "=== 2. Форматирование в ext4 ==="
mkfs.ext4 -F "$PART_ROOT"

echo "=== 3. Монтирование ==="
mkdir -p /mnt/gentoo
mount "$PART_ROOT" /mnt/gentoo

echo "=== 4. Загрузка Stage3 ==="
cd /mnt/gentoo
wget -q --show-progress "$STAGE3_URL"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
rm stage3-*.tar.xz

echo "=== 5. Монтирование системных каталогов ==="
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run

ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")

chroot /mnt/gentoo /bin/bash <<EOF
set -e
source /etc/profile
export PS1="(chroot) \$PS1"

echo "=== 5.1 Синхронизация Portage ==="
emerge-webrsync

echo "=== 5.2 Настройка бинарного репозитория ==="
echo 'PORTAGE_BINHOST="https://binhost.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"' >> /etc/portage/make.conf
echo 'FEATURES="${FEATURES} getbinpkg"' >> /etc/portage/make.conf

echo "=== 5.3 Часовой пояс и локали ==="
echo "UTC" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8

echo "=== 5.4 Генерация /etc/fstab ==="
cat << FSTAB_OUT > /etc/fstab
UUID=$ROOT_UUID / ext4 noatime 0 1
FSTAB_OUT

echo "=== 5.5 Установка бинарного ядра ==="
emerge --getbinpkg sys-kernel/gentoo-kernel-bin

echo "=== 5.6 Установка сети и утилит ==="
emerge --getbinpkg net-misc/dhcpcd sys-apps/pciutils
rc-update add dhcpcd default

echo "=== 5.7 Установка GRUB (BIOS) ==="
echo 'GRUB_PLATFORMS="pc"' >> /etc/portage/make.conf
emerge --getbinpkg sys-boot/grub
grub-install --target=i386-pc "$DISK"
grub-mkconfig -o /boot/grub/grub.cfg

echo "=== 5.8 Пользователи и пароли ==="
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel,audio,video,usb,portage,users -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd

emerge --getbinpkg app-admin/sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

echo "=== Установка успешно завершена! ==="
EOF

echo "=== 6. Размонтирование ==="
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo

echo "Готово! Можешь перезагружать виртуалку."
