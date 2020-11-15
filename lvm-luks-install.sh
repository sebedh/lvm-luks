#!/bin/bash
set -e

cat << EOF
You will enter a password to use when encrypting the disk, it will be saved to /tmp/lukpassword, write it down!

EOF
echo -n "Enter Password: "
read CRYPT_PASSWORD
if [ ${#CRYPT_PASSWORD} -lt 8 ]; then echo "Password Too Short"; exit
else echo ${CRYPT_PASSWORD} > /tmp/lukspassword
fi

if [ -f /tmp/lukspassword ]; then echo "Password is set and saved to /tmp/lukspassword"
else
	echo "Password could not be set, please check if you have write permission to /tmp"; exit
fi

echo -n "Enter disk to use: "
read DISK
if [ ! -b ${DISK} ]; then echo "Disk you entered is not a block device... exiting.."; exit
else
	echo "Using ${DISK} to setup encrypted disk on. IT WILL BE WIPED!!"
fi

read -p "Are you sure? ([yY]es)" -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit; fi

read -p "Installing NixOS?" -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then 
	export DISTRIBUTION="NixOS"
fi

# This will result in /dev/nvmen0p1, if disk was /dev/nvmen0
ROOT_PART="${DISK}p1"
BOOT_PART="${DISK}p2"

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
mkfs.fat -F 32 -n boot ${DISK}/${BOOT_PARTITION}

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
if [ ${SWAP_ON} == "true" ]; then 
	echo "Creating SWAP LV with size ${SWAP_SIZE}G"
	lvcreate -n swap -L ${SWAP_SIZE}G ${VG_NAME}
	mkswap -L swap -n ${SWAP_DEV}
else
	echo "Skipping SWAP"
fi


########### MOUNTING ############

mount /dev/${VG_NAME}/root /mnt
mkdir -p /mnt/boot
mount /dev/${BOOT_PART} /mnt/boot

for lv in ${!EXTRA_LVS[@]}; do
	mkdir -p /mnt/${lv}
	mount /dev/${VG_NAME}/${lv} /mnt/${lv}
done

if [ -z ${DISTRIBUTION+x} ] && [ ${DISTRIBUTION} == "NixOS" ]; then
	nixos-generate-config --root /mnt
fi

echo "Done, now continue manually"
