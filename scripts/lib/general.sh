#!/bin/bash

# Author: Norbert Kiszka and others
# License: GPL v2

build_cleanup()
{
	if [ "${LOOPDEV}" != "" ] && [ -e "${LOOPDEV}" ] ; then
		notice "Disconnecting ${LOOPDEV}"
		losetup -d "${LOOPDEV}" || true
	fi
	
	if [ "${TMPIMAGE}" != "" ] && [ -e "${TMPIMAGE}" ] ; then
		rm -f "${TMPIMAGE}" || true
	fi
}
trap_exit_at_first build_cleanup

host_requirements_check()
{
	sys_require_dev_null
	sys_require_dev_zero
	sys_require_tmp
}

prepare_host()
{
	#if ! hash apt-get 2> /dev/null; then
	if ! is_executable apt-get ; then
		build_error "This scripts requires a Debian based distrbution"
	fi
	
	build_info "Adding architectures into Your packaging system"
	sys_add_arch arm64
	sys_add_arch amd64
	sys_add_arch i386
	
	build_info "Retrieving/updating packages information"
	apt-get -y update
	
	build_info "Installing/updating necessary packages."
	apt-get -y --no-install-recommends --fix-missing install \
		        bash-completion tar mtools u-boot-tools pv bc git sed gawk coreutils \
		        gcc gcc-i686-linux-gnu automake make curl binfmt-support flex whiptail \
		        lib32z1 lib32z1-dev bison gettext pkg-config xz-utils mount \
		        figlet dosfstools libncurses5-dev debootstrap binutils binutils-i686-linux-gnu \
		        swig libssl-dev autopoint gettext python3 \
		        dos2unix libc6:arm64 libssl-dev build-essential gcc-multilib-i686-linux-gnu \
		        libncurses-dev bison libssl-dev libelf-dev gdisk parted \
		        libssl-dev:arm64 libssl3:arm64 libxml2-dev \
		        libxslt-dev libpython3.11-dev:arm64 device-tree-compiler \
		        mkbootimg libunwind8 libunwind8:arm64 libc6-dev libc6-dev:arm64 \
		        libgcc-12-dev-arm64-cross debootstrap qemu-user-static rsync \
		        || build_error "Failed to install required packages. Check error(s) message(s) and try again."
	
	build_info "Installing optional package(s)"
	apt-get -y --no-install-recommends --fix-missing install cowsay || true

	build_info "Host system is prepared"
}

prepare_toolchains()
{
	TOOLCHAIN_BRANCH="aarch64-linux-gnu-6.3"
	if [ ! -d "$ROOT/toolchain" ]; then
		build_info "Cloning orangepi toolchain"
		if ! git clone --depth=1 https://github.com/orangepi-xunlong/toolchain.git -b $TOOLCHAIN_BRANCH ; then
			# Something failed, so remove it for next try
			[ -d "$ROOT/toolchain" ] || rm -r "$ROOT/toolchain" || build_warning "Failed to delete directory $ROOT/toolchain"
			build_error "Failed to clone toolchain repository."
		fi
	fi
	chmod 755 -R $ROOT/toolchain/*
}

prepare_kernel()
{
	build_info "Preparing sources of a Linux kernel ..."
	if [ ! -d "$LINUX" ]; then
		if ! git clone https://github.com/norbertkiszka/rigol-orangerigol-linux_4.4.179.git "$LINUX" ; then
			# Something failed, so remove it for next try
			[ -d "$LINUX" ] || rm -r "$LINUX" || build_warning "Failed to delete directory $LINUX"
			build_error "Failed to clone Linux kernel repository"
		fi
	else
		cd "$LINUX"
		git pull || build_warning "Failed to update Linux kernel sources"
		cd -
	fi
	build_info "Sources of a Linux kernel are prepared"
}

prepare_uboot_rkbin()
{
	if [ ! -d "$EXTER_ORANGEPI" ]; then
		build_info "Preparing rkbin for a U-Boot bootloader ..."
		if ! git clone https://github.com/orangepi-xunlong/OrangePiRK3399_external.git -b orangepi-rk3399_v1.4 --depth 1 "$EXTER_ORANGEPI" ; then
			# Something failed, so remove it for next try
			[ -d "$EXTER_ORANGEPI" ] || rm -r "$EXTER_ORANGEPI" || build_warning "Failed to delete directory $EXTER_ORANGEPI"
			build_error "Failed to clone U-Boot repository"
		fi
		build_info "rkbin is ready"
	fi
}

prepare_uboot()
{
	build_info "Preparing sources of a U-Boot bootloader ..."
	if [ ! -d "$UBOOT" ]; then
		if ! git clone https://github.com/norbertkiszka/rigol-orangerigol-uboot_2017.09_light.git "$UBOOT" ; then
			# Something failed, so remove it for next try
			[ -d "$UBOOT" ] || rm -r "$UBOOT" || build_warning "Failed to delete directory $UBOOT"
			build_error "Failed to clone U-Boot repository"
		fi
	else
		cd "$UBOOT"
		git pull || build_warning "Failed to update U-Boot bootloader sources"
		cd -
	fi
	
	build_info "Sources of a U-Boot bootloader are prepared"
	
	prepare_uboot_rkbin
}

prepare_grub()
{
	build_info "Preparing sources of a GRUB bootloader ..."
	if [ ! -d "$GRUB" ]; then
		if ! git clone https://git.savannah.gnu.org/git/grub.git -b grub-2.12 "$GRUB" ; then
			# Something failed, so remove it for next try
			[ -d "$GRUB" ] || rm -r "$GRUB" || build_warning "Failed to delete directory $GRUB"
			build_error "Failed to clone GRUB repository"
		fi
# 	else
# 		cd "$GRUB"
# 		git pull || build_warning "Failed to update GRUB bootloader sources"
# 		cd -
	fi
	
	build_info "Sources of a GRUB bootloader are prepared"
}

kernel_update()
{
	build_info "Updating Linux kernel image in $INPUT_PATH ..."
	pv $BUILD/kernel/boot.img  | dd of=$INPUT_PATH seek=49152 conv=notrunc
	sync
}

modules_update()
{
	build_info "Updating Linux kernel modules in ${ROOTFS_PATH} ..."
	
	# Remove old modules
	rm -rf "${ROOTFS_PATH}/lib/modules"
	mkdir -p "${ROOTFS_PATH}/lib/modules"
	
	#cp -rfa "${BUILD}/lib/modules" "${ROOTFS_PATH}/lib/"
	sys_cpdir "${BUILD}/lib/modules/" "${ROOTFS_PATH}/lib/modules/"
	build_info "Syncing ..."
	sync
}

uboot_update()
{
	build_info "Updating U-Boot bootloader in $INPUT_PATH ..."
	dd if=$BUILD/uboot/idbloader.img of=$INPUT_PATH seek=64
	dd if=$BUILD/uboot/uboot.img of=$INPUT_PATH seek=24576
	dd if=$BUILD/uboot/trust.img of=$INPUT_PATH seek=32768
	sync
}

build_info()
{
	info ${*}
}

build_notice()
{
	notice_e "${*}\n${BASH_SOURCE[1]}:${BASH_LINENO}"
}

build_warning()
{
	warning "${*}"
}

build_error()
{
	error "${*}"
	exit 1
}

build_success_text_only()
{
	success_e "${*}"
}

build_success()
{
	build_success_text_only "${*}"
	success_whiptail "${*}"
	#exit 0
}
