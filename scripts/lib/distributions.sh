#!/bin/bash

# Author: Norbert Kiszka and others
# License: GPL v2

# TODO: mount image or SD card as rootfs

deboostrap_rootfs() {
	DIST="$1"
	TGZ="$(readlink -f "$2")"
	build_info "Preparing base system with debootstrap ..."
	TEMP=$(sys_mktempdir)

	cd $TEMP
	build_info "Entered directory `pwd`"

	# this is updated very seldom, so is ok to hardcode
	#debian_archive_keyring_deb="${SOURCES}/pool/main/d/debian-archive-keyring/debian-archive-keyring_2019.1_all.deb"
	debian_archive_keyring_deb="http://ftp.de.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2025.1_all.deb"
	[ "${OS}" == "ubuntu" ] && debian_archive_keyring_deb="http://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring/ubuntu-keyring_2023.11.28.1_all.deb"
	wget -O keyring.deb "$debian_archive_keyring_deb"
	ar -x keyring.deb && rm -f control.tar.gz debian-binary && rm -f keyring.deb
	DATA=$(ls data.tar.*) && compress=${DATA#data.tar.}

	KR="debian-archive-keyring.gpg"
	[ "${OS}" == "ubuntu" ] && KR="ubuntu-archive-keyring.gpg"
	tar --strip-components=4 -xvf "$DATA"
	ls "$DATA"
	rm -f "$DATA"
	
	debootstrap --include="locales,base-files,base-passwd,apt-utils,gawk,adduser,tar,perl,bash,bash-completion" --arch="${ARCH}" --keyring="${TEMP}/${KR}" --foreign "${DIST}" rootfs "${SOURCES}"

	chroot rootfs /debootstrap/debootstrap --second-stage
	
	mkdir -p "${TEMP}/rootfs/etc/orangerigol"
	echo "debootstrap" > "${TEMP}/rootfs/etc/orangerigol/buildstage"
	echo "${ARCH}" > "${TEMP}/rootfs/etc/orangerigol/arch"
	
	tar -C "${TEMP}/rootfs" -a -cf "${TGZ}" .
	#rm -fr "${TEMP}/rootfs"
	rm -fr "${TEMP}"
	build_info "Base system is prepared in ${TGZ}"

	cd - > /dev/null
	build_info "Entered directory `pwd`"
}

# TODO: systemd-nspawn or other container?
# Usage: build_chroot destination_path command [command arguments]
build_chroot()
{
	#cp /usr/bin/qemu-aarch64-static "$DEST/usr/bin" || build_warning "Failed to copy qemu-aarch64-static. Please check if that file exists."
	
	#qemu_dest="$DEST/usr/bin/qemu-aarch64-static"

	sys_chroot $@

	# Clean up
	#rm -f "$chroot_dest/usr/bin/qemu-aarch64-static"
}

# Executed by add_overlay()
add_overlay_error()
{
	OVERLAY_NAME="${1}"
	OVERLAY_PATH="${OVERLAYS}/${OVERLAY_NAME}"
	build_warning "Failed to add overlay ${OVERLAY_NAME}"
	if [ -e "${OVERLAY_PATH}/overlay-posterror.sh" ] ; then
		build_notice "Executing overlay-posterror.sh for a ${OVERLAY_NAME}"
		"${OVERLAY_PATH}/overlay-posterror.sh" || build_error "overlay-posterror.sh failed for ${OVERLAY_NAME}"
	fi
	if [ -d "${OVERLAY_PATH}/rootfs_postfail" ] ; then
		build_notice "rsync ${OVERLAY_NAME}/rootfs_postfail"
		if ! rsync -a  "${OVERLAY_PATH}/rootfs_postfail/" "${DEST}/" ; then
			build_error "Overlay ${OVERLAY_NAME} failed to rsync rootfs_postfail/"
		fi
	fi
}

add_overlay()
{
	OVERLAY_NAME="${1}"
	OVERLAY_PATH="${OVERLAYS}/${OVERLAY_NAME}"
	build_info "Adding overlay ${OVERLAY_NAME} ..."
	
	if [ ! -d "${OVERLAY_PATH}/rootfs" ] ; then
		build_error "Failed to add overlay ${OVERLAY_NAME}. Every overlay must have at least empty folder rootfs"
	fi
	
	if [ -e "${OVERLAY_PATH}/overlay-preinstall.sh" ] ; then
		build_info "Executing overlay-preinstall.sh for a overlay ${OVERLAY_NAME}"
		if ! "${OVERLAY_PATH}/overlay-preinstall.sh" ; then
			build_notice "Overlay ${OVERLAY_NAME}/overlay-preinstall.sh returned error"
			add_overlay_error "${OVERLAY_NAME}"
			return
		fi
	fi
	
	if [ "$(ls ${OVERLAY_PATH}/rootfs/* 2> /dev/null)" != "" ] ; then
		if ! rsync -a  ${OVERLAY_PATH}/rootfs/ $DEST/ ; then
			build_notice "Overlay ${OVERLAY_NAME} failed to rsync rootfs/"
			add_overlay_error "${OVERLAY_NAME}"
			return
		fi
	fi
	
	if [ -e "${OVERLAY_PATH}/overlay-postinstall.sh" ] ; then
		build_info "Executing overlay-postinstall.sh for a ${OVERLAY_NAME}"
		if ! "${OVERLAY_PATH}/overlay-postinstall.sh" ; then
			build_notice "Overlay ${OVERLAY_NAME}/overlay-postinstall.sh returned error"
			add_overlay_error "${OVERLAY_NAME}"
			return
		fi
	fi
	build_info "Overlay ${OVERLAY_NAME} was added"
}

add_overlays_preinstall()
{
	build_info "Adding overlays: preinstall ..."
	if [ "${ARCH}" == "arm" ] || [ "${ARCH}" == "arm64" ] ; then
		add_overlay mali-proprietary-driver
	fi
	add_overlay skel
	add_overlay firmware
	add_overlay images
	echo "overlays_preinstall" >> "${DEST}/etc/orangerigol/buildstage"
	build_info "Overlays added: preinstall"
}

add_overlays_postinstall()
{
	build_info "Adding overlays: postinstall ..."
	[ "$CPU" == "RK3399" ] && add_overlay systemd-nosuspend
	[ "$CPU" == "RK3399" ] && add_overlay cpufrequtils-rk3399
	rm -rf $DEST/etc/update-motd.d/*
	add_overlay motd
	#add_overlay mali-proprietary-driver
	if [ "$(cat $DEST/etc/orangerigol/buildstage | grep -F "desktop")" != "" ] ; then
		if [ "$(awk -F: '$3 == 1000 {print $1}' "${DEST}/etc/passwd")" != "" ] ; then
			# We have "main" user, so make him autologin
			add_overlay gdm3_autologin
		else
			# Looks like nobody to autologin, beside of a root...
			add_overlay gdm3_noautologin
		fi
		add_overlay dconf # TODO use postinstall or something else to execute dconf update
		build_chroot "${DEST}" "/usr/bin/dconf update" || build_warning "Failed to update dconf database. Please execute [# dconf update (enter)] and [$ dconf load / < /etc/dconf/db/local.d/00-orangerigol (enter)] after running it on target device."
	fi
	add_overlay mpv
	echo "overlays_postinstall" >> "${DEST}/etc/orangerigol/buildstage"
	build_info "Overlays added: postinstall"
}

add_overlays_always()
{
	build_info "Adding overlays: always ..." # Dont ask.
	add_overlay orangerigol-scripts
	echo "overlays_always" >> "${DEST}/etc/orangerigol/buildstage"
	build_info "Overlays added: always"
}

# debootstrap sources are very basic
add_apt_sources()
{
	build_info "Adding apt sources ..."
	local release="$1"
	local aptsrcfile="${DEST}/etc/apt/sources.list"
	# Make sure sources.list exists
	mkdir -p $DEST/etc/apt
	touch "${aptsrcfile}"
	if [ "${OS}" == "debian" ] ; then
		cat > "$aptsrcfile" <<EOF
deb ${SOURCES} ${release} main contrib non-free non-free-firmware
# deb-src ${SOURCES} ${release} main contrib non-free 
deb http://security.debian.org/debian-security ${release}-security main contrib non-free non-free-firmware

# for older packages (oldstable):
#deb ${SOURCES} bullseye main non-free contrib
#deb http://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
# 	else
# 		cat > "$aptsrcfile" <<EOF
# deb ${SOURCES} ${release} main restricted universe multiverse
# deb http://security.ubuntu.com/ubuntu ${release}-security main restricted universe multiverse
# deb ${SOURCES} ${release}-updates main restricted universe multiverse
# EOF
	fi
}

# This is where Debian is born
prepare_env()
{
	build_info "Preparing rootfs enviroment ..."
	
	mkdir -p $DEST
	
	TARBALL="$EXTER/$(basename $ROOTFS)"

	if [ ! -e "$TARBALL" ]; then
		if [ "$METHOD" = "download" ]; then
			build_info "Downloading $DISTRO rootfs tarball ..."
			wget -O "$TARBALL" "$ROOTFS"
		elif [ "$METHOD" = "debootstrap" ]; then
			deboostrap_rootfs "$DISTRO" "$TARBALL"
		else
			build_error "Unknown rootfs creation method"
		fi
	fi

	# Extract with tar
	build_info "Extracting base system from $TARBALL ..."
	mkdir -p $DEST
	$UNTAR "$TARBALL" -C "$DEST"
	build_info "Base system is extracted in ${DEST}"
	
	# For a compatilibity with v0.1
	# TODO: delete if its old (mtime)
	if [ ! -d "${DEST}/etc/orangerigol" ] || [ ! -e "${DEST}/etc/orangerigol/buildstage" ] ; then
		if [ "${METHOD}" != "download" ] ; then
			build_warning "Looks like tarball is outdated. Please consider deleting it in external/*.tar.gz (that will force to make new one)."
		fi
		mkdir -p "${DEST}/etc/orangerigol"
		echo "debootstrap" > "${DEST}/etc/orangerigol/buildstage"
	fi
	
	add_overlays_preinstall
}

# Make sure we are safe to go
ckeck_apt_archives_cache_lock()
{
	if [ -e "${BUILD_APT_ARCHIVES_CACHE}lock" ] && [ $(lsof "${BUILD_APT_ARCHIVES_CACHE}lock" 2> /dev/null | wc -l) -gt 0 ]; then
		build_error "Unable to lock directory ${BUILD_APT_ARCHIVES_CACHE}\n \
${BUILD_APT_ARCHIVES_CACHE}lock is held by process "`lsof ${BUILD_APT_ARCHIVES_CACHE}lock 2> /dev/null | grep "${BUILD_APT_ARCHIVES_CACHE}lock"  | awk '{ print $2 }'`" ("`lsof ${BUILD_APT_ARCHIVES_CACHE}lock 2> /dev/null | grep "${BUILD_APT_ARCHIVES_CACHE}lock"  | awk '{ print $1 }'`")"
	fi
}

prepare_base_system()
{
	build_info "Installing base packages ..."
	cp /etc/resolv.conf "$DEST/etc/resolv.conf" || build_error "Cant continue wihout /etc/resolv.conf. Please check if that file exists on Your system."
	
	add_apt_sources $DISTRO
	rm -rf "$DEST/etc/apt/sources.list.d/proposed.list"
	ckeck_apt_archives_cache_lock
	build_chroot "${DEST}" orangerigol-install-base
	cat > "${DEST}/etc/resolv.conf" <<EOF
nameserver 8.8.8.8
EOF
	echo "base_system" >> ${DEST}/etc/orangerigol/buildstage

	#cd $BUILD
	#tar czf ${DISTRO}_server_rootfs.tar.gz rootfs
	#cd - > /dev/null
	
	build_info "Base packages installed"
}

add_user()
{
	build_chroot "${DEST}" /usr/local/bin/orangerigol-adduser $@
}

add_user_root()
{
	cat > "${DEST}/add_user_root" <<EOF
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
mkdir -p /root
[ "\$(id -nu 0 2> /dev/null)" != "" ] || useradd -p rigol -s /bin/bash -u 0 -U root -d /root || echo "User root already exists..."
rsync -a /etc/skel/.[^.]* /root/
chown -R 0:0 /root
chmod 700 /root
echo root:rigol | chpasswd
EOF
	chmod +x "${DEST}/add_user_root"
	build_chroot "${DEST}" /add_user_root
	rm -f "${DEST}/add_user_root"
	touch "${DEST}/etc/orangerigol/build_added_users"
	[ "$(cat "${DEST}/etc/orangerigol/build_added_users" | grep "root")" != "" ] || echo "root" >> "${DEST}/etc/orangerigol/build_added_users"
}

user_setup()
{
	add_user_root
	if [ "${CHOSEN_USERNAME}" == "" ] ; then
		build_notice "CHOSEN_USERNAME is empty. No user will be added."
	else
		[ "$(awk -F: '$3 == 1000 {print $1}' "${DEST}/etc/passwd")" == "" ] || build_chroot "${DEST}" deluser "${CHOSEN_USERNAME}" # In case of interruption or other error.
		add_user "${CHOSEN_USERNAME}" 1000
	fi
	echo "user_setup" >> "${DEST}/etc/orangerigol/buildstage"
}

basic_setup()
{
	build_info "Configuring system ..."

	cat > "${DEST}/etc/hostname" <<EOF
orangerigol
EOF
	cat > "${DEST}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 orangerigol

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
	cat > "${DEST}/etc/resolv.conf" <<EOF
nameserver 8.8.8.8
EOF

	sed -i 's|After=rc.local.service|#\0|;' "${DEST}/lib/systemd/system/serial-getty@.service"

	# Bring back folders
	mkdir -p "${DEST}/lib"
	mkdir -p "${DEST}/usr/local"

	# Create fstab
	cat  > "${DEST}/etc/fstab" <<EOF
# <file system>	<dir>	<type>	<options>				<dump>	<pass>

UUID=${ROOT_UUID}	/	ext4	defaults,noatime			0		1
EOF
	
	if [ ! -d "${DEST}/lib/modules" ]; then
		mkdir -p "${DEST}/lib/modules"
	else
		rm -rf "${DEST}/lib/modules"
		mkdir -p "${DEST}/lib/modules"
	fi
	
	if [ "${KERNEL_METHOD}" == "compile" ] ; then
		build_info "Installing Linux kernel modules ..."
		make -C $LINUX ARCH="${ARCH}" CROSS_COMPILE="${TOOLS}" modules_install INSTALL_MOD_PATH="${DEST}"

		build_info "Installing Linux kernel headers ..."
		make -C $LINUX ARCH="${ARCH}" CROSS_COMPILE="${TOOLS}" headers_install INSTALL_HDR_PATH="${DEST}/usr/local"
	fi
	
	echo "basic_setup" >> "${DEST}/etc/orangerigol/buildstage"
}

install_mate_desktop()
{
	build_info "Installing desktop enviroment: Mate"
	ckeck_apt_archives_cache_lock
	build_chroot "${DEST}" orangerigol-install-desktop-mate
	sync
	echo "desktop" >> "${DEST}/etc/orangerigol/buildstage"
	echo "desktop_mate" >> "${DEST}/etc/orangerigol/buildstage"
	sync
	build_info "Installed desktop enviroment: Mate"
}

rootfs_finals()
{
	cat > "${DEST}/type-phase" <<EOF
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

apt-get -y update
apt-get -y dist-upgrade
EOF
	chmod +x "${DEST}/type-phase"
	build_chroot "${DEST}" /type-phase
	rm -f "$DEST/type-phase"
	echo "rootfs_finals" >> "${DEST}/etc/orangerigol/buildstage"
	sync
}

add_version_files()
{
	mkdir -p "${DEST}/etc/orangerigol"
	echo "${BUILD_VERSION_TEXT}" > "${DEST}/etc/orangerigol/buildversiontext"
	echo "${BUILD_GIT_SHORT}" > "${DEST}/etc/orangerigol/gitshort"
}

remove_version_files()
{
	[ ! -e "${DEST}/etc/orangerigol/buildversiontext" ] || rm "${DEST}/etc/orangerigol/buildversiontext"
	[ ! -e "${DEST}/etc/orangerigol/gitshort" ] || rm "${DEST}/etc/orangerigol/gitshort"
}

build_rootfs()
{
	# Remove version files in case of interruption to avoid confusion when restarted with different commit or when something else was changed.
	remove_version_files
	build_cleanup
	
	if [ ! -e "${DEST}" ] ; then
		build_info "Destination directory doesnt exist. Executing fresh build."
		prepare_env
	elif [ ! -e "$DEST/etc/orangerigol/buildstage" ] || [ "$(cat "${DEST}/etc/orangerigol/buildstage" | grep "overlays_preinstall")" == "" ] ; then
		build_notice "Very old build in rootfs or interrupted at at very early stage. Deleting it and starting from the beginning."
		[ ! -e "${DEST}" ] || rm -r "${DEST}"
		prepare_env
	else
		if [ "$DIFFICULTY" == "expert" ] ; then
			# TODO: move it somwhere earlier
			if whiptail --title "Orange Rigol Build System" --yesno "Rootfs already exists at ${DEST}.\n\nSelect <Yes> to continue (fastest).\n\nSelect <No> to remove it and start build from the beginning (safest)." 15 120 ; then
				CONTINUE_IN_EXISTING_ROOTFS=1
			else
				CONTINUE_IN_EXISTING_ROOTFS=0
			fi
		else
			CONTINUE_IN_EXISTING_ROOTFS=0
		fi
		
		if [ "$CONTINUE_IN_EXISTING_ROOTFS" == "1" ] ; then
			build_notice "Continuing in existing rootfs"
		else
			build_notice "Removing existing rootfs and building it from the beginning"
			rm -r "${DEST}"
			chose_username # Since we deleted old rootfs
			prepare_env
		fi
	fi
	
	echo "${ARCH}" > "${DEST}/etc/orangerigol/arch"
	add_overlays_always
	
	if [ "$(cat "${DEST}/etc/orangerigol/buildstage" | grep "base_system")" == "" ] ; then
		prepare_base_system
	else
		build_notice "Already in buildstage: base_system"
	fi
	
	if [ "$(cat "${DEST}/etc/orangerigol/buildstage" | grep "basic_setup")" == "" ] ; then
		basic_setup
	else
		build_notice "Already in buildstage: basic_setup"
	fi
	
	if [ "$(cat "${DEST}/etc/orangerigol/buildstage" | grep "user_setup")" == "" ] ; then
		user_setup
	else
		build_notice "Already in buildstage: user_setup"
	fi
	
	build_info "Base system is prepared"
	
	if [ "$IMAGETYPE" = "desktop" ] || [ "$IMAGETYPE" = "desktop-oscilloscope" ] ; then
		if [ "$(cat "${DEST}/etc/orangerigol/buildstage" | grep "desktop")" == "" ] ; then
			install_mate_desktop
		else
			build_notice "Already in buildstage: desktop"
		fi
	fi
	
	build_info "Finishing rootfs"
	
	rootfs_finals
	add_overlays_postinstall
	add_version_files
	
	echo "build_ready" >> "${DEST}/etc/orangerigol/buildstage"
	
	build_info "Rootfs (system) is ready to use"
}
