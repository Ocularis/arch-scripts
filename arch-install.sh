#!/bin/bash

set -e
command -v whiptail >/dev/null 2>&1 || { echo "whiptail required for this script" >&2 ; exit 1 ; }

cehck_net_connectivity() {
	echo "## checking net connectivity"
	ping -c 2 resolver1.opendns.com
	#ip route add default via <gw-ip>
}

enable_ssh() {
	systemctl start sshd 
	echo "## set passwd for login with ssh root@<ip>"
	passwd
	ip addr | grep "inet"
}

set_variables() {
	echo "## defining variables for installation"

	# cat /etc/locale.gen | grep -oP "^#\K[a-zA-Z0-9@._-]+"
	locale=$(whiptail --nocancel --inputbox "Set locale:" 10 40 "en_GB.UTF-8" 3>&1 1>&2 2>&3)

	keyboard=$(whiptail --nocancel --inputbox "Set keyboard:" 10 40 "no" 3>&1 1>&2 2>&3)
	zone=$(whiptail --nocancel --inputbox "Set zone:" 10 40 "Europe" 3>&1 1>&2 2>&3)
	subzone=$(whiptail --nocancel --inputbox "Set subzone:" 10 40 "Norway" 3>&1 1>&2 2>&3)
	country=$(whiptail --nocancel --inputbox "Set mirrorlist country code:" 10 40 "NO" 3>&1 1>&2 2>&3)

	new_uuid=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
	hostname=$(whiptail --nocancel --inputbox "Set hostname:" 10 40 "arch-$new_uuid" 3>&1 1>&2 2>&3)

	# [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS
	enable_uefi=false
	if whiptail --defaultno --yesno "install for UEFI system?" 8 40 ; then
		enable_uefi=true
	fi
}

update_locale() {
	echo "## updating locale"
	loadkeys $keyboard
	export LANG=$locale
	sed -i -e "s/#$locale/$locale/" /etc/locale.gen
	locale-gen
}

partition_disk() {
	disks=`parted --list | awk -F ": |, |Disk | " '/Disk \// { print $2" "$3$4 }'`
	DSK=$(whiptail --nocancel --menu "Select the Disk to install to" 18 45 10 $disks 3>&1 1>&2 2>&3)

	echo "## WILL COMPLETELY WIPE ${DSK}"
	read -p "Press [Enter] key to continue"
	sgdisk --zap-all ${DSK}

	enable_trim=false
	if [ -n "$(hdparm -I ${DSK} 2>&1 | grep 'TRIM supported')" ]; then
		echo "## detected TRIM support"
		enable_trim=true
	fi

	labelroot="arch-root"
	labelswap="arch-swap"
	labelboot="arch-boot"
	partroot="/dev/disk/by-partlabel/$labelroot"
	partswap="/dev/disk/by-partlabel/$labelswap"
	partboot="/dev/disk/by-partlabel/$labelboot"

	swap_size=`awk '/MemTotal/ {printf( "%.0f\n", $2 / 1000 )}' /proc/meminfo`
	swap_size=$(whiptail --nocancel --inputbox "Set swap partition size \n(recommended based on meminfo):" 10 40 "$swap_size" 3>&1 1>&2 2>&3)

	if $enable_uefi ; then
		esp_end=501
		labelesp="arch-esp"
		partesp="/dev/disk/by-partlabel/$labelesp"
	else
		esp_end=2
	fi

	boot_end=$(( ${esp_end} + 500 ))
	swap_end=$(( $boot_end + ${swap_size} ))

	echo "## creating partition bios_grub"
	parted -s ${DSK} mklabel gpt

	if $enable_uefi ; then
		parted -s ${DSK} -a optimal unit MB mkpart ESI 1 ${esp_end}
		parted -s ${DSK} set 1 boot on
		parted -s ${DSK} mkfs 1 fat32
		parted -s ${DSK} name 1 $labelesp
	else
		parted -s ${DSK} -a optimal unit MB mkpart primary 1 ${esp_end}
		parted -s ${DSK} set 1 bios_grub on
	fi

	echo "## creating partition $labelboot"
	parted -s ${DSK} -a optimal unit MB mkpart primary ${esp_end} $boot_end
	parted -s ${DSK} name 2 $labelboot

	echo "## creating partition $labelswap"
	parted -s ${DSK} -a optimal unit MB mkpart primary linux-swap $boot_end $swap_end
	parted -s ${DSK} name 3 $labelswap

	echo "## creating partition $labelroot"
	parted -s ${DSK} -a optimal unit MB -- mkpart primary $swap_end -1
	parted -s ${DSK} name 4 $labelroot

	whiptail --title "generated partition layout" --msgbox "`parted -s ${DSK} print`" 20 70
}

format_disk() {
	if $enable_uefi ; then
		mkfs.vfat -F 32 $partesp
	fi

	echo "## mkfs $partboot"
	mkfs.ext4 $partboot

	mountpoint="/mnt"

	enable_luks=false
	if whiptail --defaultno --yesno "encrypt root and swap partitions?" 8 40 ; then
		enable_luks=true

		maproot="croot"
		mapswap="cswap"

		echo "## encrypting $partroot"
		cryptsetup --batch-mode --force-password --verify-passphrase --cipher aes-xts-plain64 --key-size 512 --hash sha512 luksFormat $partroot
		echo "## opening $partroot"
		cryptsetup luksOpen $partroot $maproot
		echo "## mkfs /dev/mapper/$maproot"
		mkfs.ext4 /dev/mapper/$maproot
		mount /dev/mapper/$maproot $mountpoint
	else
		echo "## mkfs $partroot"
		mkfs.ext4 $partroot
		mount $partroot $mountpoint

		mkswap $partswap
		swapon $partswap
	fi

	mkdir -p $mountpoint/boot
	mount $partboot $mountpoint/boot

	if $enable_uefi ; then
		mkdir -p $mountpoint/boot/efi
		mount $partesp $mountpoint/boot/efi
	fi
}

update_mirrorlist() {
	echo "## attempting to download mirrorlist for country: ${country}"
	mirrorlist_url="https://www.archlinux.org/mirrorlist/?country=${country}&use_mirror_status=on"

	mirrorlist_tmp=$(mktemp --suffix=-mirrorlist)
	curl -so ${mirrorlist_tmp} ${mirrorlist_url}
	sed -i 's/^#Server/Server/g' ${mirrorlist_tmp}

	if [[ -s ${mirrorlist_tmp} ]]; then
		echo "## rotating the new list into place"
		mv -i /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.orig &&
		mv -i ${mirrorlist_tmp} /etc/pacman.d/mirrorlist
	else
		echo "## could not download list, ranking original mirrorlist"
		cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
		sed '/^#\S/ s|#||' -i /etc/pacman.d/mirrorlist.backup
		rankmirrors --verbose -n 6 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist
	fi

	chmod +r /etc/pacman.d/mirrorlist
	nano /etc/pacman.d/mirrorlist
}

install_base(){
	echo "## installing base system"
	pacstrap $mountpoint base base-devel dialog
}

configure_fstab(){
	echo "## generating fstab entries"
	genfstab -U -p $mountpoint >> $mountpoint/etc/fstab

	if $enable_luks ; then
		echo "$mapswap $partswap /dev/urandom swap,cipher=aes-xts-plain:sha256,size=256" >> $mountpoint/etc/crypttab
		echo "/dev/mapper/$mapswap none swap defaults 0 0" >> $mountpoint/etc/fstab
	fi

	if $enable_trim ; then
		echo "## adding trim support"
		sed -i -e 's/defaults/defaults,discard/' $mountpoint/etc/fstab

		if $enable_luks ; then
			sed -i -e 's/rw,/discard,rw,/' $mountpoint/etc/fstab
			sed -i -e 's/swap,/swap,discard,/' $mountpoint/etc/crypttab
		fi
	fi

	nano $mountpoint/etc/fstab

	if $enable_luks ; then
		nano $mountpoint/etc/crypttab
	fi
}

arch_chroot(){
	arch-chroot $mountpoint /bin/bash -c "${1}"
}

configure_system(){
	echo "## updating locale"
	sed -i -e "s/#$locale/$locale/" $mountpoint/etc/locale.gen
	arch_chroot "locale-gen"
	echo LANG=$locale > $mountpoint/etc/locale.conf
	arch_chroot "export LANG=$locale"

	if $enable_luks ; then
		echo "## adding encrypt hook"
		sed -i -e "/^HOOKS/s/filesystems/encrypt filesystems/" $mountpoint/etc/mkinitcpio.conf
		arch_chroot "mkinitcpio -p linux"
	fi

	echo "## writing vconsole.conf"
	echo "KEYMAP=$keyboard" > $mountpoint/etc/vconsole.conf
	echo "FONT=Lat2-Terminus16" >> $mountpoint/etc/vconsole.conf

	echo "## updating localtime"
	arch_chroot "ln -s /usr/share/zoneinfo/$zone/$subzone /etc/localtime"
	arch_chroot "hwclock --systohc --utc"

	echo "## setting hostname"
	echo $hostname > $mountpoint/etc/hostname
}

install_bootloader()
{
	echo "## installing grub to ${DSK}"
	pacstrap $mountpoint grub

	#/etc/machine-id 
	#uname -r
	#/etc/os-release

	if $enable_uefi ; then
		pacstrap $mountpoint dosfstools efibootmgr
		arch_chroot "grub-install --root-directory=/boot --boot-directory=/boot/efi --target=x86_64-efi --bootloader-id=boot --recheck ${DSK}"
	else
		arch_chroot "grub-install --recheck ${DSK}"
	fi

	if $enable_luks ; then
		cryptdevice="cryptdevice=$partroot:$maproot"

		if $enable_trim ; then 
			echo "## appending allow-discards for TRIM support"
			cryptdevice+=":allow-discards"
		fi
		sed -i -e "\#^GRUB_CMDLINE_LINUX=#s#\"\$#$cryptdevice\"#" $mountpoint/etc/default/grub
		sed -i -e "s/#GRUB_DISABLE_LINUX_UUID/GRUB_DISABLE_LINUX_UUID/" $mountpoint/etc/default/grub
	fi

	if ! grep -q "GRUB_DISABLE_SUBMENU=y" $mountpoint/etc/default/grub ; then
		echo -e "\nGRUB_DISABLE_SUBMENU=y" | sudo tee --append $mountpoint/etc/default/grub
	fi

	nano $mountpoint/etc/default/grub
	arch_chroot "grub-mkconfig -o /boot/grub/grub.cfg"

	if $enable_luks ; then
		whiptail --title "check cryptdevice in grub.cfg" --msgbox "`cat $mountpoint/boot/grub/grub.cfg | grep -m 1 "cryptdevice"`" 20 80
	fi
}

create_user() {
	if whiptail --yesno "create a user for this installation?" 8 40 ; then
		username=$(whiptail --nocancel --inputbox "Set username:" 10 40 "$new_uuid" 3>&1 1>&2 2>&3)
		echo "## adding user: $username"
		pacstrap $mountpoint sudo
		arch_chroot "useradd -m -g users -G wheel,audio,network,power,storage,optical -s /bin/bash $username"
		echo "## set password for user: $username"
		arch_chroot "passwd $username"
		sed -i '/%wheel ALL=(ALL) ALL/s/^#//' $mountpoint/etc/sudoers
	fi
}

install_network_daemon() {
	enable_networkmanager=false

	case $(whiptail --menu "Choose a network daemon" 20 60 12 \
	"1" "NetworkManager" \
	"2" "dhcpcd" \
	"3" "bonding (netctl)" \
	3>&1 1>&2 2>&3) in
		1)
			echo "## installing networkmanager"
			pacstrap $mountpoint networkmanager
			arch_chroot "systemctl enable NetworkManager && systemctl enable NetworkManager-dispatcher.service"
			enable_networkmanager=true
		;;
    	2)
			echo "## enabling dhcpcd"
			arch_chroot "systemctl enable dhcpcd.service"
		;;
		3)
			echo "#installing netctl"
			pacstrap $mountpoint netctl ifenslave
			cp $mountpoint/etc/netctl/examples/bonding $mountpoint/etc/netctl/bonding
			# append interface names in comment into $mountpoint/etc/netctl/bonding
			nano $mountpoint/etc/netctl/bonding
			#arch_chroot "netctl enable profile"
	esac	
}

enable_ntpd() {
	if whiptail --yesno "enable network time daemon?" 8 40 ; then
		echo "## enabling network time daemon"
		pacstrap $mountpoint ntp

		if $enable_networkmanager ; then
			pacstrap $mountpoint networkmanager-dispatcher-ntpd
		fi

		arch_chroot "ntpd -q"
		#arch_chroot "hwclock -w"
		arch_chroot "systemctl enable ntpd.service"
	fi
}

enable_sshd() {
	if whiptail --yesno "enable ssh daemon?" 8 40 ; then
		pacstrap $mountpoint openssh
		arch_chroot "systemctl enable sshd.service"
	fi
}

finish_setup() {
	# offer to umount | reboot | poweroff | do nothing
	if whiptail --yesno "Reboot now?" 8 40 ; then
		echo "## unmounting and rebooting"

		if $enable_uefi ; then
			umount -l $mountpoint/boot/efi
		fi
		umount -l $mountpoint/boot
		umount -l $mountpoint

		if $enable_luks ; then
			cryptsetup luksClose $maproot
		fi

		reboot
	fi
}

set_variables
update_locale
partition_disk
format_disk
update_mirrorlist
install_base
configure_fstab
configure_system
install_bootloader
create_user
install_network_daemon
enable_ntpd
enable_sshd
finish_setup
