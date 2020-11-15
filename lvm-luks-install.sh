#!/bin/bash
set -e

cat << EOF
You will enter a password to use when encrypting the disk, it will be saved to /tmp/lukpassword, write it down!

EOF
echo -n "Enter Password: "
read -rs CRYPT_PASSWORD
if [ ${#CRYPT_PASSWORD} -lt 8 ]; then echo "Password Too Short"; exit
else echo ${CRYPT_PASSWORD} > /tmp/lukspassword
fi

if [ -f /tmp/lukspassword ]; then echo "Password is set and saved to /tmp/lukspassword"
else
	echo "Password could not be set, please check if you have write permission to /tmp"; exit
fi

echo -n "Enter disk to use (For example /dev/sda or /dev/nvme0): "
read DISK
if [ ! -b ${DISK} ]; then echo "Enter full path to block device... exiting.."; exit
else
	echo "Using ${DISK} to setup encrypted disk on. IT WILL BE WIPED!!"
fi

while true; do
	read -p "Are you sure, it will wiped? ([yY]|[nN])" -n 1 yn
	case $yn in
		[Yy]* ) echo; break;;
		[Nn]* ) exit;;
		* ) echo "[Yy]es or [Nn]o.";;
	esac
done
echo
echo "Installing NixOS?"
select yn in "Yes" "No"; do
	case $yn in
		Yes) DISTRIBUTION="NixOS"; break;;
		No) exit;;
	esac
done

echo

############## VARIABLE SETTINGS

# Sets root and boot partion variables depending on nvme0 type or sda/vga
case ${DISK#/dev/} in
	sda | vga)
		ROOT_PART="${DISK}1"
		BOOT_PART="${DISK}2"
		;;
	nvme0)
		ROOT_PART="${DISK}n1p1"
		BOOT_PART="${DISK}n1p2"
		;;
	nvme0n1)
		ROOT_PART="${DISK}p1"
		BOOT_PART="${DISK}p2"
		;;
	*)
		echo "No valid disk type.."
		;;
esac

SWAP_ON=true
SWAP_SIZE=8

# CRYPTSETTINGS
CRYPT_OPEN_NAME="cryptlv"

# LVM SETTINGS
VG_NAME="vg00"
MAPPER_DIR="/dev/mapper"
ROOT_DEV="/dev/${VG_NAME}/root"
SWAP_DEV="/dev/${VG_NAME}/swap"

ROOT_SIZE="10G"
declare -A EXTRA_LVS=( ["var"]="8G" ["usr"]="4G" ["home"]="40G" )

# SETUP Partitions
echo "SETTING UP PARTITIONS"
parted ${DISK} -- mklabel gpt
parted ${DISK} -- mkpart primary 512MiB 100%

# SETUP BOOT Partition
echo "SETTING UP BOOT PARTITIONS"
parted ${DISK} -- mkpart esp fat32 1MiB 512MiB
parted ${DISK} -- set 2 esp on

if [ -b ${BOOT_PART} ]; then 
	echo "Formating ${BOOT_PART}"
	mkfs.fat -F 32 -n boot ${BOOT_PART}
else
	echo "Could not find boot block device"
	exit
fi

# SETUP CRYPT FOR DISK ENCRYPTION
cryptsetup -y -v --type luks2 luksFormat ${ROOT_PART} -d /tmp/lukspassword
cryptsetup open ${ROOT_PART} ${CRYPT_OPEN_NAME} -d /tmp/lukspassword

# SETUP PV & VG
echo "Setting up PV and VG"
pvcreate ${MAPPER_DIR}/${CRYPT_OPEN_NAME}
vgcreate ${VG_NAME} ${MAPPER_DIR}/${CRYPT_OPEN_NAME}

# ROOT LV
echo "Setting up ROOT LV"
lvcreate -n root -L ${ROOT_SIZE} ${VG_NAME}
mkfs.ext4 /dev/${VG_NAME}/root

# CREATE AND FORMAT EXTRA LV Partitions
echo "Setting up extra LVS"
for lv in ${!EXTRA_LVS[@]}; do
	lvcreate -n ${lv} -L ${EXTRA_LVS[$lv]} ${VG_NAME}
	mkfs.ext4 /dev/${VG_NAME}/${lv}
done

# SETUP SWAP
echo "Setting up extra LVS"
if [ "${SWAP_ON}" = "true" ]; then 
	echo "Creating SWAP LV with size ${SWAP_SIZE}G"
	lvcreate -n swap -L ${SWAP_SIZE}G ${VG_NAME}
	mkswap -L swap ${SWAP_DEV}
else
	echo "Skipping SWAP"
fi

########### MOUNTING ############

mount /dev/${VG_NAME}/root /mnt
mkdir -p /mnt/boot
mount ${BOOT_PART} /mnt/boot

for lv in ${!EXTRA_LVS[@]}; do
	mkdir -p /mnt/${lv}
	mount /dev/${VG_NAME}/${lv} /mnt/${lv}
done

if [ "${DISTRIBUTION}" = "NixOS" ]; then
	nixos-generate-config --root /mnt
	CRYPT_UUID=`blkid | grep "TYPE=\"crypto_LUKS\"" | cut -d "\"" -f2`
	echo "$CRYPT_UUID" > /tmp/uuid_crypt

fi

echo "Done, now continue manually, saved uuid of crypt device in /tmp/uuid_crypt"
