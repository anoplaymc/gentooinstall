#!/bin/bash
set -e

# Конфигурация
DISK="/dev/nvme0n1"
ROOT_PASS="lk2020"
USER_NAME="anoplay"
USER_PASS="lk2020"
GENTOO_MIRROR="https://distfiles.gentoo.org"

echo "=== 1. Разметка диска ($DISK) ==="
wipefs -a "$DISK"
sgdisk -Z "$DISK"

# Разделы: 1: EFI (1 ГБ), 2: ROOT (остальное)
sgdisk -n 1:1M:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT" "$DISK"

PART_EFI="${DISK}p1"
PART_ROOT="${DISK}p2"

# Проверка создания разделов
sleep 2
mkfs.fat -F32 "$PART_EFI"
mkfs.ext4 -F "$PART_ROOT"

echo "=== 2. Монтирование файловых систем ==="
mount "$PART_ROOT" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "$PART_EFI" /mnt/gentoo/efi

echo "=== 3. Загрузка Stage3 (OpenRC) ==="
cd /mnt/gentoo

# Получаем ссылку на актуальный Stage3 с OpenRC
STAGE3_PATH=$(curl -s "${GENTOO_MIRROR}/releases/amd64/autobuilds/current-stage3-amd64-openrc/" | grep -oE 'stage3-amd64-openrc-[0-9T]+\.tar\.xz' | head -n 1)
FULL_URL="${GENTOO_MIRROR}/releases/amd64/autobuilds/current-stage3-amd64-openrc/${STAGE3_PATH}"

echo "Загрузка архива: $FULL_URL"
wget -q --show-progress "$FULL_URL"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
rm stage3-*.tar.xz

echo "=== 4. Монтирование служебных каталогов ==="
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run

echo "=== 5. Переход в chroot и настройка системы ==="

# Получаем UUID разделов до входа в chroot
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")

chroot /mnt/gentoo /bin/bash <<EOF
set -e
source /etc/profile
export PS1="(chroot) \$PS1"

echo "=== 5.1 Синхронизация Portage ==="
emerge-webrsync

echo "=== 5.2 Включение бинарных пакетов (Binhost) ==="
echo 'EMERGE_DEFAULT_OPTS="--binhost-getbinpkg=y --getbinpkg=y"' >> /etc/portage/make.conf
echo 'FEATURES="${FEATURES} getbinpkg binpkg-multi-instance"' >> /etc/portage/make.conf

echo "=== 5.3 Часовой пояс и локаль ==="
echo "UTC" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8

echo "=== 5.4 Генерация /etc/fstab ==="
cat << FSTAB_OUT > /etc/fstab
UUID=$ROOT_UUID / ext4 noatime 0 1
UUID=$EFI_UUID /efi vfat umask=0077 0 2
FSTAB_OUT

echo "=== 5.5 Установка бинарного ядра ==="
emerge --getbinpkg=y sys-kernel/gentoo-kernel-bin

echo "=== 5.6 Установка сети и утилит OpenRC ==="
emerge --getbinpkg=y net-misc/dhcpcd sys-apps/pciutils
rc-update add dhcpcd default

echo "=== 5.7 Установка и настройка GRUB (UEFI) ==="
echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
emerge --getbinpkg=y sys-boot/grub

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo
grub-mkconfig -o /boot/grub/grub.cfg

echo "=== 5.8 Настройка пользователей и паролей ==="
echo "root:$ROOT_PASS" | chpasswd

# Создаем пользователя anoplay и добавляем в основные группы
useradd -m -G wheel,audio,video,usb,portage,users -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd

# Предоставляем группе wheel доступ к sudo / su (опционально)
emerge --getbinpkg=y app-admin/sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

echo "=== Настройка завершена! ==="
EOF

echo "=== 6. Размонтирование дисков ==="
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo

echo "Готово! Система Gentoo (OpenRC) успешно установлена. Вы можете выполнить 'reboot'."
