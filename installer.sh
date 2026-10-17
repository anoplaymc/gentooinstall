#!/bin/bash
set -e

# Конфигурация для виртуальной машины (BIOS + /dev/vda)
DISK="/dev/vda"
ROOT_PASS="lk2020"
USER_NAME="anoplay"
USER_PASS="lk2020"
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/20261011T170049Z/stage3-amd64-openrc-20261011T170049Z.tar.xz"

echo "=== 1. Разметка диска ($DISK) для BIOS ==="
wipefs -a "$DISK"
# Создаем классическую MBR таблицу разделов через sfdisk
echo "label: dos" | sfdisk "$DISK"

# Создаем единственный корневой раздел на весь диск с загрузочным флагом (bootable)
echo ",,L,*" | sfdisk "$DISK"

PART_ROOT="${DISK}1"

# Пауза для инициализации устройства ядром
sleep 2

echo "=== 2. Форматирование раздела в ext4 ==="
mkfs.ext4 -F "$PART_ROOT"

echo "=== 3. Монтирование файловой системы ==="
mkdir -p /mnt/gentoo
mount "$PART_ROOT" /mnt/gentoo

echo "=== 4. Загрузка Stage3 (OpenRC) ==="
cd /mnt/gentoo

echo "Загрузка: $STAGE3_URL"
wget -q --show-progress "$STAGE3_URL"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
rm stage3-*.tar.xz

echo "=== 5. Монтирование служебных каталогов ==="
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run

echo "=== 6. Получение UUID и вход в chroot ==="
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")

chroot /mnt/gentoo /bin/bash <<EOF
set -e
source /etc/profile
export PS1="(chroot) \$PS1"

echo "=== 6.1 Синхронизация Portage ==="
emerge-webrsync

echo "=== 6.2 Включение бинарных пакетов (Binhost) ==="
echo 'EMERGE_DEFAULT_OPTS="--binhost-getbinpkg=y --getbinpkg=y"' >> /etc/portage/make.conf
echo 'FEATURES="${FEATURES} getbinpkg binpkg-multi-instance"' >> /etc/portage/make.conf

echo "=== 6.3 Часовой пояс и локаль ==="
echo "UTC" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8

echo "=== 6.4 Генерация /etc/fstab ==="
cat << FSTAB_OUT > /etc/fstab
UUID=$ROOT_UUID / ext4 noatime 0 1
FSTAB_OUT

echo "=== 6.5 Установка бинарного ядра ==="
emerge --getbinpkg=y sys-kernel/gentoo-kernel-bin

echo "=== 6.6 Установка сети и базовых утилит (OpenRC) ==="
emerge --getbinpkg=y net-misc/dhcpcd sys-apps/pciutils
rc-update add dhcpcd default

echo "=== 6.7 Установка и настройка GRUB (BIOS/i386-pc) ==="
# Для BIOS платформ явно указываем поддержку pc
echo 'GRUB_PLATFORMS="pc"' >> /etc/portage/make.conf
emerge --getbinpkg=y sys-boot/grub

# Установка загрузчика в MBR всего диска (не в раздел!)
grub-install --target=i386-pc "$DISK"
grub-mkconfig -o /boot/grub/grub.cfg

echo "=== 6.8 Настройка пользователей и паролей ==="
echo "root:$ROOT_PASS" | chpasswd

useradd -m -G wheel,audio,video,usb,portage,users -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd

emerge --getbinpkg=y app-admin/sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

echo "=== Внутренняя установка завершена успешно! ==="
EOF

echo "=== 7. Размонтирование дисков ==="
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo

echo "Готово! Gentoo OpenRC (BIOS) установлена на виртуальный диск $DISK. Можно выключать виртуалку и загружаться."
