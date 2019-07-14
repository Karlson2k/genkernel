#!/bin/bash
# $Id$

COPY_BINARIES=false
CPIO_ARGS="--quiet -o -H newc --owner root:root --force-local"

# The copy_binaries function is explicitly released under the CC0 license to
# encourage wide adoption and re-use. That means:
# - You may use the code of copy_binaries() as CC0 outside of genkernel
# - Contributions to this function are licensed under CC0 as well.
# - If you change it outside of genkernel, please consider sending your
#   modifications back to genkernel@gentoo.org.
#
# On a side note: "Both public domain works and the simple license provided by
#                  CC0 are compatible with the GNU GPL."
#                 (from https://www.gnu.org/licenses/license-list.html#CC0)
#
# Written by:
# - Sebastian Pipping <sebastian@pipping.org> (error checking)
# - Robin H. Johnson <robbat2@gentoo.org> (complete rewrite)
# - Richard Yao <ryao@cs.stonybrook.edu> (original concept)
# Usage:
# copy_binaries DESTDIR BINARIES...
copy_binaries() {
	local destdir=${1}
	shift

	if [ ! -f "${TEMP}/.binaries_copied" ]
	then
		touch "${TEMP}/.binaries_copied" \
			|| gen_die "Failed to set '${TEMP}/.binaries_copied' marker!"
	fi

	local binary
	for binary in "$@"
	do
		[[ -e "${binary}" ]] \
			|| gen_die "Binary ${binary} could not be found"

		if LC_ALL=C lddtree "${binary}" 2>&1 | fgrep -q 'not found'
		then
			gen_die "Binary ${binary} is linked to missing libraries and may need to be re-built"
		fi
	done
	# This must be OUTSIDE the for loop, we only want to run lddtree etc ONCE.
	# lddtree does not have the -V (version) nor the -l (list) options prior to version 1.18
	(
		if lddtree -V > /dev/null 2>&1
		then
			lddtree -l "$@" \
				|| gen_die "Binary '${binary}' or some of its library dependencies could not be copied!"
		else
			lddtree "$@" \
				| tr ')(' '\n' \
				| awk '/=>/{ if($3 ~ /^\//){print $3}}' \
				|| gen_die "Binary '${binary}' or some of its library dependencies could not be copied!"
		fi
	) \
		| sort \
		| uniq \
		| cpio -p --make-directories --dereference --quiet "${destdir}" \
		|| gen_die "Binary '${binary}' or some of its library dependencies could not be copied!"
}

log_future_cpio_content() {
	print_info 2 "=================================================================" 1 0 1
	print_info 2 "About to add these files from '${PWD}' to cpio archive:" 1 0 1
	print_info 2 "$(find . | xargs ls -ald)" 1 0 1
	print_info 2 "=================================================================" 1 0 1
}

append_devices() {
	local TFILE="${TEMP}/initramfs-base-temp.devices"
	if [ -f "${TFILE}" ]
	then
		rm "${TFILE}" || gen_die "Failed to clean out existing '${TFILE}'!"
	fi

	if [[ ! -x "${KERNEL_OUTPUTDIR}/usr/gen_init_cpio" ]]; then
		compile_gen_init_cpio
	fi

	# WARNING, does NOT support appending to cpio!
	cat >"${TFILE}" <<-EOF
	dir /dev 0755 0 0
	nod /dev/console 660 0 0 c 5 1
	nod /dev/null 666 0 0 c 1 3
	nod /dev/zero 666 0 0 c 1 5
	nod /dev/tty0 600 0 0 c 4 0
	nod /dev/tty1 600 0 0 c 4 1
	nod /dev/ttyS0 600 0 0 c 4 64
	EOF

	print_info 2 "=================================================================" 1 0 1
	print_info 2 "Adding the following devices to cpio:" 1 0 1
	print_info 2 "$(cat "${TFILE}")" 1 0 1
	print_info 2 "=================================================================" 1 0 1

	"${KERNEL_OUTPUTDIR}"/usr/gen_init_cpio "${TFILE}" >"${CPIO}" \
		|| gen_die "Failed to append devices to cpio!"
}

append_base_layout() {
	local TDIR="${TEMP}/initramfs-base-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	mkdir "${TDIR}" || gen_die "Failed to create '${TDIR}'!"
	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"

	local mydir=
	for mydir in \
		.initrd \
		bin \
		dev \
		etc \
		etc/mdev/helpers \
		lib \
		mnt \
		proc \
		run \
		sbin \
		sys \
		tmp \
		usr \
		usr/bin \
		usr/lib \
		usr/sbin \
		var/log \
	; do
		mkdir -p "${TDIR}"/${mydir} || gen_die "Failed to create '${TDIR}/${mydir}'!"
	done

	ln -s ../run var/run || gen_die "Failed to create symlink '${TDIR}/var/run' to '${TDIR}/run'!"

	chmod 1777 "${TDIR}"/tmp || gen_die "Failed to chmod of '${TDIR}/tmp' to 1777!"

	# In general, we don't really need lib{32,64} anymore because we now
	# compile most stuff on our own and therefore don't have to deal with
	# multilib anymore. However, when copy_binaries() was used to copy
	# binaries from a multilib-enabled system, this could be a problem.
	# So let's keep symlinks to ensure that all libraries will land in
	# /lib.
	local myliblink
	for myliblink in \
		lib32 \
		lib64 \
		usr/lib32 \
		usr/lib64 \
	; do
		ln -s lib ${myliblink} || gen_die "Failed to create symlink '${TDIR}/${myliblink}' to '${TDIR}/lib'!"
	done

	print_info 2 "$(get_indent 2)>> Populating '/etc/fstab' ..."
	echo "/dev/ram0     /           ext2    defaults	0 0" > "${TDIR}"/etc/fstab \
		|| gen_die "Failed to add /dev/ram0 to '${TDIR}/etc/fstab'!"

	echo "proc          /proc       proc    defaults    0 0" >> "${TDIR}"/etc/fstab \
		|| gen_die "Failed to add proc to '${TDIR}/etc/fstab'!"

	print_info 2 "$(get_indent 2)>> Adding /etc/ld.so.conf ..."
	cat >"${TDIR}"/etc/ld.so.conf <<-EOF
	# ld.so.conf generated by genkernel
	include ld.so.conf.d/*.conf
	/lib
	/usr/lib
	EOF

	print_info 2 "$(get_indent 2)>> Adding misc files ..."
	date -u '+%Y-%m-%d %H:%M:%S UTC' > "${TDIR}"/etc/build_date \
		|| gen_die "Failed to create '${TDIR}/etc/build_date'!"

	echo "Genkernel $GK_V" > "${TDIR}"/etc/build_id \
		|| gen_die "Failed to create '${TDIR}/etc/build_id'!"

	dd if=/dev/zero of="${TDIR}/var/log/lastlog" bs=1 count=0 seek=0 &>/dev/null \
		|| die "Failed to create '${TDIR}/var/log/lastlog'!"

	dd if=/dev/zero of="${TDIR}/var/log/wtmp" bs=1 count=0 seek=0 &>/dev/null \
		|| die "Failed to create '${TDIR}/var/log/wtmp'!"

	dd if=/dev/zero of="${TDIR}/run/utmp" bs=1 count=0 seek=0 &>/dev/null \
		|| die "Failed to create '${TDIR}/run/utmp'!"

	print_info 2 "$(get_indent 2)>> Adding mdev config ..."
	install -m 644 -t "${TDIR}"/etc "${GK_SHARE}"/mdev/mdev.conf \
		|| gen_die "Failed to install '${GK_SHARE}/mdev/mdev.conf'!"

	install -m 755 -t "${TDIR}"/etc/mdev/helpers "${GK_SHARE}"/mdev/helpers/nvme \
		|| gen_die "Failed to install '${GK_SHARE}/mdev/helpers/nvme'!"

	install -m 755 -t "${TDIR}"/etc/mdev/helpers "${GK_SHARE}"/mdev/helpers/storage-device \
		|| gen_die "Failed to install '${GK_SHARE}/mdev/helpers/storage-device'!"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append baselayout to cpio!"
}

append_busybox() {
	local PN=busybox
	local TDIR="${TEMP}/initramfs-${PN}-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	populate_binpkg ${PN}

	mkdir "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"

	# Delete unneeded files
	rm -rf configs/

	mkdir -p "${TDIR}"/usr/share/udhcpc || gen_die "Failed to create '${TDIR}/usr/share/udhcpc'!"

	cp -a "${GK_SHARE}"/defaults/udhcpc.scripts usr/share/udhcpc/default.script 2>/dev/null \
		|| gen_die "Failed to copy '${GK_SHARE}/defaults/udhcpc.scripts' to '${TDIR}/usr/share/udhcpc/default.script'!"

	local myfile=
	for myfile in \
		bin/busybox \
		usr/share/udhcpc/default.script \
	; do
		chmod +x "${TDIR}"/${myfile} || gen_die "Failed to chmod of '${TDIR}/${myfile}'!"
	done

	# Set up a few default symlinks
	local required_applets='[ ash sh mount uname echo cut cat'
	local required_applet=
	for required_applet in ${required_applets}
	do
		ln -s busybox "${TDIR}"/bin/${required_applet} \
			|| gen_die "Failed to create Busybox symlink for '${required_applet}' applet!"
	done

	# allow for DNS resolution
	local libdir=$(get_chost_libdir)
	mkdir -p "${TDIR}"/lib || gen_die "Failed to create '${TDIR}/lib'!"
	copy_system_binaries "${TDIR}"/lib "${libdir}"/libnss_dns.so.2

	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append ${PN} to cpio!"
}

append_e2fsprogs() {
	local PN=e2fsprogs
	local TDIR="${TEMP}/initramfs-${PN}-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	populate_binpkg ${PN}

	mkdir "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"

	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append ${PN} to cpio!"
}

append_blkid() {
	local PN="util-linux"
	local TDIR="${TEMP}/initramfs-blkid-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	populate_binpkg ${PN}

	mkdir -p "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"

	# Delete unneeded files
	rm -rf usr/

	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append blkid to cpio!"
}

#append_fuse() {
#	if [ -d "${TEMP}/initramfs-fuse-temp" ]
#	then
#		rm -r "${TEMP}/initramfs-fuse-temp"
#	fi
#	cd ${TEMP}
#	mkdir -p "${TEMP}/initramfs-fuse-temp/lib/"
#	tar -C "${TEMP}/initramfs-fuse-temp/lib/" -xf "${FUSE_BINCACHE}"
#	cd "${TEMP}/initramfs-fuse-temp/"
#	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
#			|| gen_die "compressing fuse cpio"
#	rm -rf "${TEMP}/initramfs-fuse-temp" > /dev/null
#}

append_unionfs_fuse() {
	local PN=unionfs-fuse
	local TDIR="${TEMP}/initramfs-${PN}-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	populate_binpkg ${PN}

	mkdir -p "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append ${PN} to cpio!"
}

#append_suspend(){
#	if [ -d "${TEMP}/initramfs-suspend-temp" ];
#	then
#		rm -r "${TEMP}/initramfs-suspend-temp/"
#	fi
#	print_info 1 "$(getIndent 2)SUSPEND: Adding support (compiling binaries)..."
#	compile_suspend
#	mkdir -p "${TEMP}/initramfs-suspend-temp/"
#	/bin/tar -xpf "${SUSPEND_BINCACHE}" -C "${TEMP}/initramfs-suspend-temp" ||
#		gen_die "Could not extract suspend binary cache!"
#	mkdir -p "${TEMP}/initramfs-suspend-temp/etc"
#	cp -f /etc/suspend.conf "${TEMP}/initramfs-suspend-temp/etc" ||
#		gen_die 'Could not copy /etc/suspend.conf'
#	cd "${TEMP}/initramfs-suspend-temp/"
#	log_future_cpio_content
#	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
#			|| gen_die "compressing suspend cpio"
#	rm -r "${TEMP}/initramfs-suspend-temp/"
#}

append_multipath(){
	if [ -d "${TEMP}/initramfs-multipath-temp" ]
	then
		rm -r "${TEMP}/initramfs-multipath-temp"
	fi
	print_info 1 "$(getIndent 2)Multipath: Adding support (using system binaries)..."
	mkdir -p "${TEMP}"/initramfs-multipath-temp/{bin,etc,sbin,lib}/

	# Copy files
	copy_binaries "${TEMP}/initramfs-multipath-temp" \
		/bin/mountpoint \
		/sbin/{multipath,kpartx,dmsetup} \
		/{lib,lib64}/{udev/scsi_id,multipath/*so}

	# Support multipath-tools-0.4.8 and previous
	if [ -x /sbin/mpath_prio_* ]
	then
		copy_binaries "${TEMP}/initramfs-multipath-temp" \
			/sbin/mpath_prio_*
	fi

	if [ -x /sbin/multipath ]
	then
		cp /etc/multipath.conf "${TEMP}/initramfs-multipath-temp/etc/" || gen_die 'could not copy /etc/multipath.conf please check this'
	fi
	# /etc/scsi_id.config does not exist in newer udevs
	# copy it optionally.
	if [ -x /sbin/scsi_id -a -f /etc/scsi_id.config ]
	then
		cp /etc/scsi_id.config "${TEMP}/initramfs-multipath-temp/etc/" || gen_die 'could not copy scsi_id.config'
	fi
	cd "${TEMP}/initramfs-multipath-temp"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing multipath cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-multipath-temp/"
}

append_dmraid() {
	local PN=dmraid
	local TDIR="${TEMP}/initramfs-${PN}-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	populate_binpkg ${PN}

	mkdir "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"

	# Delete unneeded files
	rm -rf \
		usr/lib \
		usr/share \
		usr/include

	mkdir -p "${TDIR}"/var/lock/dmraid || gen_die "Failed to create '${TDIR}/var/lock/dmraid'!"

	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append dmraid to cpio!"
}

append_iscsi() {
	local PN=open-iscsi
	local TDIR="${TEMP}/initramfs-${PN}-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	populate_binpkg ${PN}

	mkdir -p "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append iscsi to cpio!"
}

append_lvm() {
	local PN=lvm
	local TDIR="${TEMP}/initramfs-${PN}-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	populate_binpkg ${PN}

	mkdir "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"

	local mydir=
	for mydir in \
		etc/lvm/cache \
		sbin \
	; do
		mkdir -p ${mydir} || gen_die "Failed to create '${TDIR}/${mydir}'!"
	done

	# Delete unneeded files
	rm -rf \
		usr/lib \
		usr/share \
		usr/include

	# Include the LVM config
	if [ -x /sbin/lvm -o -x /bin/lvm ]
	then
		local ABORT_ON_ERRORS=$(kconfig_get_opt "/etc/lvm/lvm.conf" "abort_on_errors")
		if isTrue "${ABORT_ON_ERRORS}" && [[ ${CBUILD} == ${CHOST} ]]
		then
			# Make sure the LVM binary we created is able to handle
			# system's lvm.conf
			"${TDIR}"/sbin/lvm dumpconfig 1>"${TDIR}"/etc/lvm/lvm.conf 2>/dev/null \
				|| gen_die "Bundled LVM version does NOT support system's lvm.conf!"

			# Sanity check
			if [ ! -s "${TDIR}/etc/lvm/lvm.conf" ]
			then
				gen_die "Sanity check failed: '${TDIR}/etc/lvm/lvm.conf' looks empty?!"
			fi
		else
			cp -aL /etc/lvm/lvm.conf "${TDIR}"/etc/lvm/lvm.conf 2>/dev/null \
				|| gen_die "Failed to copy '/etc/lvm/lvm.conf'!"
		fi

		# Some LVM config options need changing, because the functionality is
		# not compiled in:
		sed -r -i \
			-e '/^[[:space:]]*obtain_device_list_from_udev/s,=.*,= 0,g' \
			-e '/^[[:space:]]*use_lvmetad/s,=.*,= 0,g' \
			-e '/^[[:space:]]*use_lvmlockd/s,=.*,= 0,g' \
			-e '/^[[:space:]]*use_lvmpolld/s,=.*,= 0,g' \
			-e '/^[[:space:]]*monitoring/s,=.*,= 0,g' \
			-e '/^[[:space:]]*external_device_info_source/s,=.*,= "none",g' \
			-e '/^[[:space:]]*units/s,=.*"r",= "h",g' \
			"${TDIR}"/etc/lvm/lvm.conf \
				|| gen_die 'Could not sed lvm.conf!'
	fi

	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append lvm to cpio!"
}

append_mdadm(){
	if [ -d "${TEMP}/initramfs-mdadm-temp" ]
	then
		rm -r "${TEMP}/initramfs-mdadm-temp/"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-mdadm-temp/etc/"
	mkdir -p "${TEMP}/initramfs-mdadm-temp/sbin/"
	if isTrue "${MDADM}"
	then
		if [ -n "${MDADM_CONFIG}" ]
		then
			if [ -f "${MDADM_CONFIG}" ]
			then
				cp -a "${MDADM_CONFIG}" "${TEMP}/initramfs-mdadm-temp/etc/mdadm.conf" \
				|| gen_die "Could not copy mdadm.conf!"
			else
				gen_die "${MDADM_CONFIG} does not exist!"
			fi
		else
			print_info 1 "$(getIndent 2)MDADM: Skipping inclusion of mdadm.conf"
		fi

		if [ -e '/sbin/mdadm' ] && LC_ALL="C" ldd /sbin/mdadm | grep -q 'not a dynamic executable' \
		&& [ -e '/sbin/mdmon' ] && LC_ALL="C" ldd /sbin/mdmon | grep -q 'not a dynamic executable'
		then
			print_info 1 "$(getIndent 2)MDADM: Adding support (using local static binaries /sbin/mdadm and /sbin/mdmon)..."
			cp /sbin/mdadm /sbin/mdmon "${TEMP}/initramfs-mdadm-temp/sbin/" ||
				gen_die 'Could not copy over mdadm!'
		else
			print_info 1 "$(getIndent 2)MDADM: Adding support (compiling binaries)..."
			compile_mdadm
			/bin/tar -xpf "${MDADM_BINCACHE}" -C "${TEMP}/initramfs-mdadm-temp" ||
				gen_die "Could not extract mdadm binary cache!";
		fi
	fi
	cd "${TEMP}/initramfs-mdadm-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing mdadm cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-mdadm-temp" > /dev/null
}

append_zfs(){
	if [ -d "${TEMP}/initramfs-zfs-temp" ]
	then
		rm -r "${TEMP}/initramfs-zfs-temp"
	fi

	mkdir -p "${TEMP}/initramfs-zfs-temp/etc/zfs"

	# Copy files to /etc/zfs
	for i in zdev.conf zpool.cache
	do
		if [ -f /etc/zfs/${i} ]
		then
			print_info 1 "$(getIndent 2)zfs: >> Including ${i}"
			cp -a "/etc/zfs/${i}" "${TEMP}/initramfs-zfs-temp/etc/zfs" 2> /dev/null \
				|| gen_die "Could not copy file ${i} for ZFS"
		fi
	done

	if [ -f "/etc/hostid" ]
	then
		local _hostid=$(hostid)
		print_info 1 "$(getIndent 2)zfs: >> Embedding hostid '${_hostid}' into initramfs..."
		cp -a /etc/hostid "${TEMP}/initramfs-zfs-temp/etc" 2> /dev/null \
			|| gen_die "Failed to copy /etc/hostid"

		echo "${_hostid}" > "${TEMP}/.embedded_hostid"
	else
		print_info 2 "$(getIndent 2)zfs: /etc/hostid not found; You must use 'spl_hostid' kernel command-line parameter!"
	fi

	copy_binaries "${TEMP}/initramfs-zfs-temp" /sbin/{mount.zfs,zdb,zfs,zpool}

	cd "${TEMP}/initramfs-zfs-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing zfs cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-zfs-temp" > /dev/null
}

append_btrfs() {
	if [ -d "${TEMP}/initramfs-btrfs-temp" ]
	then
		rm -r "${TEMP}/initramfs-btrfs-temp"
	fi

	mkdir -p "${TEMP}/initramfs-btrfs-temp"

	# Copy binaries
	copy_binaries "${TEMP}/initramfs-btrfs-temp" /sbin/btrfs

	cd "${TEMP}/initramfs-btrfs-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing btrfs cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-btrfs-temp" > /dev/null
}

append_libgcc_s() {
	if [ -d "${TEMP}/initramfs-libgcc_s-temp" ]
	then
		rm -r "${TEMP}/initramfs-libgcc_s-temp"
	fi

	mkdir -p "${TEMP}/initramfs-libgcc_s-temp"

	# Include libgcc_s.so.1:
	#   - workaround for zfsonlinux/zfs#4749
	#   - required for LUKS2 (libargon2 uses pthread_cancel)
	local libgccpath
	if type gcc-config 2>&1 1>/dev/null; then
		libgccpath="/usr/lib/gcc/$(s=$(gcc-config -c); echo ${s%-*}/${s##*-})/libgcc_s.so.1"
	fi
	if [[ ! -f ${libgccpath} ]]; then
		libgccpath="/usr/lib/gcc/*/*/libgcc_s.so.1"
	fi

	# Copy binaries
	copy_binaries "${TEMP}/initramfs-libgcc_s-temp" ${libgccpath}
	cd "${TEMP}/initramfs-libgcc_s-temp/lib64"
	ln -s "..${libgccpath}"

	cd "${TEMP}/initramfs-libgcc_s-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing libgcc_s cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-libgcc_s-temp" > /dev/null
}

append_linker() {
	if [ -d "${TEMP}/initramfs-linker-temp" ]
	then
		rm -r "${TEMP}/initramfs-linker-temp"
	fi

	mkdir -p "${TEMP}/initramfs-linker-temp/etc"

	if [ -e "/etc/ld.so.conf" ]
	then
		cp "/etc/ld.so.conf" "${TEMP}/initramfs-linker-temp/etc/" 2> /dev/null \
			|| gen_die "Could not copy ld.so.conf"
	fi
	if [ -e "/etc/ld.so.cache" ]
	then
		cp "/etc/ld.so.cache" "${TEMP}/initramfs-linker-temp/etc/" 2> /dev/null \
			|| gen_die "Could not copy ld.so.cache"
	fi
	if [ -d "/etc/ld.so.conf.d" ]
	then
		mkdir -p "${TEMP}/initramfs-linker-temp/etc/ld.so.conf.d"
		cp -r "/etc/ld.so.conf.d" "${TEMP}/initramfs-linker-temp/etc/" 2> /dev/null \
			|| gen_die "Could not copy ld.so.conf.d"
	fi

	cd "${TEMP}/initramfs-linker-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing linker cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-linker-temp" > /dev/null
}

append_splash(){
	splash_geninitramfs=`which splash_geninitramfs 2>/dev/null`
	if [ -x "${splash_geninitramfs}" ] && grep -q -E '^CONFIG_FRAMEBUFFER_CONSOLE=[y|m]' ${KERNEL_CONFIG}
	then
		[ -z "${SPLASH_THEME}" ] && [ -e /etc/conf.d/splash ] && source /etc/conf.d/splash
		[ -z "${SPLASH_THEME}" ] && SPLASH_THEME=default
		print_info 1 "$(getIndent 1)>> Installing splash [ using the ${SPLASH_THEME} theme ]..."
		if [ -d "${TEMP}/initramfs-splash-temp" ]
		then
			rm -r "${TEMP}/initramfs-splash-temp/"
		fi
		mkdir -p "${TEMP}/initramfs-splash-temp"
		cd /
		local tmp=""
		[ -n "${SPLASH_RES}" ] && tmp="-r ${SPLASH_RES}"
		splash_geninitramfs -c "${TEMP}/initramfs-splash-temp" ${tmp} ${SPLASH_THEME} || gen_die "Could not build splash cpio archive"
		if [ -e "/usr/share/splashutils/initrd.splash" ]; then
			mkdir -p "${TEMP}/initramfs-splash-temp/etc"
			cp -f "/usr/share/splashutils/initrd.splash" "${TEMP}/initramfs-splash-temp/etc"
		fi
		cd "${TEMP}/initramfs-splash-temp/"
		log_future_cpio_content
		find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing splash cpio"
		cd "${TEMP}"
		rm -r "${TEMP}/initramfs-splash-temp/"
	else
		print_warning 1 "$(getIndent 1)>> No splash detected; skipping!"
	fi
}

append_overlay(){
	cd ${INITRAMFS_OVERLAY}
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing overlay cpio"
}

append_luks() {
	local _luks_error_format="LUKS support cannot be included: %s. Please emerge sys-fs/cryptsetup."
	local _luks_source=/sbin/cryptsetup
	local _luks_dest=/sbin/cryptsetup

	if [ -d "${TEMP}/initramfs-luks-temp" ]
	then
		rm -r "${TEMP}/initramfs-luks-temp/"
	fi

	mkdir -p "${TEMP}/initramfs-luks-temp/lib/luks/"
	mkdir -p "${TEMP}/initramfs-luks-temp/sbin"
	cd "${TEMP}/initramfs-luks-temp"

	if isTrue "${LUKS}"
	then
		[ -x "${_luks_source}" ] \
				|| gen_die "$(printf "${_luks_error_format}" "no file ${_luks_source}")"

		print_info 1 "$(getIndent 2)LUKS: Adding support (using system binaries)..."
		copy_binaries "${TEMP}/initramfs-luks-temp/" /sbin/cryptsetup
	fi

	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "appending cryptsetup to cpio"

	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-luks-temp/"
}

append_dropbear() {
	local PN=dropbear
	local TDIR="${TEMP}/initramfs-${PN}-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	local dropbear_command=
	if ! isTrue "$(is_valid_ssh_host_keys_parameter_value "${SSH_HOST_KEYS}")"
	then
		gen_die "--ssh-host-keys value '${SSH_HOST_KEYS}' is unsupported!"
	elif [[ "${SSH_HOST_KEYS}" == 'create' ]]
	then
		dropbear_command=dropbearkey
	else
		dropbear_command=dropbearconvert
	fi

	local ssh_authorized_keys_file=$(expand_file "${SSH_AUTHORIZED_KEYS_FILE}")
	if [ -z "${ssh_authorized_keys_file}" ]
	then
		gen_die "--ssh-authorized-keys value '${SSH_AUTHORIZED_KEYS_FILE}' is invalid!"
	elif [ ! -f "${ssh_authorized_keys_file}" ]
	then
		gen_die "authorized_keys file '${ssh_authorized_keys_file}' does NOT exist!"
	elif [ ! -s "${ssh_authorized_keys_file}" ]
	then
		gen_die "authorized_keys file '${ssh_authorized_keys_file}' is empty!"
	fi

	populate_binpkg ${PN}

	mkdir -p "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	if [[ "${SSH_HOST_KEYS}" == 'runtime' ]]
	then
		print_info 2 "$(get_indent 2)${PN}: >> No SSH host key embedded due to --ssh-host-key=runtime; Dropbear will generate required host key(s) at runtime!"
	else
		if ! hash ssh-keygen &>/dev/null
		then
			gen_die "'ssh-keygen' program is required but missing!"
		fi

		local initramfs_dropbear_dir="${TDIR}/etc/dropbear"

		if [[ "${SSH_HOST_KEYS}" == 'create-from-host' ]]
		then
			print_info 3 "$(get_indent 2)${PN}: >> Checking for existence of all SSH host keys ..."
			local missing_ssh_host_keys=no

			if [ ! -f "/etc/ssh/ssh_host_rsa_key" ]
			then
				print_info 3 "$(get_indent 2)${PN}: >> SSH host key '/etc/ssh/ssh_host_rsa_key' is missing!"
				missing_ssh_host_keys=yes
			fi

			if [ ! -f "/etc/ssh/ssh_host_ecdsa_key" ]
			then
				print_info 3 "$(get_indent 2)${PN}: >> SSH host key '/etc/ssh/ssh_host_ecdsa_key' is missing!"
				missing_ssh_host_keys=yes
			fi

			if isTrue "${missing_ssh_host_keys}"
			then
				# Should only happen when installing a new system ...
				print_info 3 "$(get_indent 2)${PN}: >> Creating missing SSH host key(s) ..."
				ssh-keygen -A || gen_die "Failed to generate host's SSH host key(s) using 'ssh-keygen -A'!"
			fi
		fi

		local -a required_dropbear_host_keys=(
			/etc/dropbear/dropbear_ecdsa_host_key
			/etc/dropbear/dropbear_rsa_host_key
		)

		local i=0
		local n_required_dropbear_keys=${#required_dropbear_host_keys[@]}
		local required_key=
		while [[ ${i} < ${n_required_dropbear_keys} ]]
		do
			required_key=${required_dropbear_host_keys[${i}]}
			print_info 3 "$(get_indent 2)${PN}: >> Checking for existence of dropbear host key '${required_key}' ..."
			if [[ -f "${required_key}" ]]
			then
				if [[ ! -s "${required_key}" ]]
				then
					print_info 1 "$(get_indent 2)${PN}: >> Dropbear host key '${required_key}' exists but is empty; Removing ..."
					rm "${required_key}" || gen_die "Failed to remove invalid '${required_key}' null byte file!"
				elif [[ "${SSH_HOST_KEYS}" == 'create-from-host' ]] \
					&& [[ "${required_key}" == *_rsa_* ]] \
					&& [[ "${required_key}" -ot "/etc/ssh/ssh_host_rsa_key" ]]
				then
					print_info 1 "$(get_indent 2)${PN}: >> Dropbear host key '${required_key}' exists but is older than '/etc/ssh/ssh_host_rsa_key'; Removing to force update due to --ssh-host-key=create-from-host ..."
					rm "${required_key}" || gen_die "Failed to remove outdated '${required_key}' file!"
				elif [[ "${SSH_HOST_KEYS}" == 'create-from-host' ]] \
					&& [[ "${required_key}" == *_ecdsa_* ]] \
					&& [[ "${required_key}" -ot "/etc/ssh/ssh_host_ecdsa_key" ]]
				then
					print_info 1 "$(get_indent 2)${PN}: >> Dropbear host key '${required_key}' exists but is older than '/etc/ssh/ssh_host_ecdsa_key'; Removing to force update due to --ssh-host-key=create-from-host ..."
					rm "${required_key}" || gen_die "Failed to remove outdated '${required_key}' file!"
				else
					print_info 3 "$(get_indent 2)${PN}: >> Dropbear host key '${required_key}' exists!"
					unset required_dropbear_host_keys[${i}]
				fi
			else
				print_info 3 "$(get_indent 2)${PN}: >> Dropbear host key '${required_key}' is missing! Will create ..."
			fi

			i=$((i + 1))
		done

		if [[ ${#required_dropbear_host_keys[@]} -gt 0 ]]
		then
			if isTrue "$(can_run_programs_compiled_by_genkernel)"
			then
				dropbear_command="${TDIR}/usr/bin/${dropbear_command}"
				print_info 3 "$(get_indent 2)${PN}: >> Will use '${dropbear_command}' to create missing keys ..."
			elif hash ${dropbear_command} &>/dev/null
			then
				print_info 3 "$(get_indent 2)${PN}: >> Will use existing '${dropbear_command}' program from path to create missing keys ..."
			else
				local error_msg="Need to generate '${required_host_keys[*]}' but '${dropbear_command}'"
				error_msg=" program is missing. Please install net-misc/dropbear and re-run genkernel!"
				gen_die "${error_msg}"
			fi

			local missing_key=
			for missing_key in ${required_dropbear_host_keys[@]}
			do
				dropbear_create_key "${missing_key}" "${dropbear_command}"

				# just in case ...
				if [ -f "${missing_key}" ]
				then
					print_info 3 "$(get_indent 2)${PN}: >> Dropbear host key '${missing_key}' successfully created!"
				else
					gen_die "Sanity check failed: '${missing_key}' should exist at this stage but does NOT."
				fi
			done
		else
			print_info 2 "$(get_indent 2)${PN}: >> Using existing dropbear host keys from /etc/dropbear ..."
		fi

		cp -aL --target-directory "${initramfs_dropbear_dir}" /etc/dropbear/{dropbear_rsa_host_key,dropbear_ecdsa_host_key} \
			|| gen_die "Failed to copy '/etc/dropbear/{dropbear_rsa_host_key,dropbear_ecdsa_host_key}'"

		# Try to show embedded dropbear host key details for security reasons.
		# We do it that complicated to get common used formats.
		local -a key_info_files=()
		local -a missing_key_info_files=()

		local host_key_file= host_key_file_checksum= host_key_info_file=
		while IFS= read -r -u 3 -d $'\0' host_key_file
		do
			host_key_file_checksum=$(sha256sum "${host_key_file}" 2>/dev/null | awk '{print $1}')
			if [ -z "${host_key_file_checksum}" ]
			then
				gen_die "Failed to generate SHA256 checksum of '${host_key_file}'!"
			fi

			host_key_info_file="${GK_V_CACHEDIR}/$(basename "${host_key_file}").${host_key_file_checksum:0:10}.info"

			if [ ! -s "${host_key_info_file}" ]
			then
				missing_key_info_files+=( ${host_key_info_file} )
			else
				key_info_files+=( ${host_key_info_file} )
			fi
		done 3< <(find "${initramfs_dropbear_dir}" -type f -name '*_key' -print0 2>/dev/null)
		unset host_key_file host_key_file_checksum host_key_info_file
		IFS="${GK_DEFAULT_IFS}"

		if [[ ${#missing_key_info_files[@]} -ne 0 ]]
		then
			dropbear_command=
			if isTrue "$(can_run_programs_compiled_by_genkernel)"
			then
				dropbear_command="${TDIR}/usr/bin/dropbearconvert"
				print_info 3 "$(get_indent 2)${PN}: >> Will use '${dropbear_command}' to extract embedded host key information ..."
			elif hash dropbearconvert &>/dev/null
			then
				dropbear_command=dropbearconvert
				print_info 3 "$(get_indent 2)${PN}: >> Will use existing '${dropbear_command}' program to extract embedded host key information ..."
			else
				print_warning 2 "$(get_indent 2)${PN}: >> 'dropbearconvert' program not available; Cannot generate missing key information for ${#missing_key_info_files[@]} key(s)!"
			fi

			if [[ -n "${dropbear_command}" ]]
			then
				# We are missing at least information for one embedded key
				# but looks like we are able to generate the missing information ...
				local missing_key_info_file=
				for missing_key_info_file in "${missing_key_info_files[@]}"
				do
					dropbear_generate_key_info_file "${dropbear_command}" "${missing_key_info_file}" "${initramfs_dropbear_dir}"
					key_info_files+=( ${missing_key_info_file} )
				done
				unset missing_key_info_file
			fi
		fi

		if [[ ${#key_info_files[@]} -gt 0 ]]
		then
			# We have at least information about one embedded key ...
			print_info 1 "=================================================================" 1 0 1
			print_info 1 "This initramfs' sshd will use the following host key(s):" 1 0 1

			local key_info_file=
			for key_info_file in "${key_info_files[@]}"
			do
				print_info 1 "$(cat "${key_info_file}")" 1 0 1
			done
			unset key_info_file

			if [ ${LOGLEVEL} -lt 3 ]
			then
				# Don't clash with output from log_future_cpio_content
				print_info 1 "=================================================================" 1 0 1
			fi
		else
			print_warning 2 "$(get_indent 2)${PN}: >> No information about embedded SSH host key(s) available."
		fi
	fi

	local libdir=$(get_chost_libdir)
	mkdir -p "${TDIR}"/lib || gen_die "Failed to create '${TDIR}/lib'!"
	copy_system_binaries "${TDIR}"/lib "${libdir}"/libnss_files.so.2

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"

	cp -a "${GK_SHARE}"/defaults/login-remote.sh "${TDIR}"/usr/bin/ \
		|| gen_die "Failed to copy '${GK_SHARE}/defaults/login-remote.sh'"

	cp -a "${GK_SHARE}"/defaults/resume-boot.sh "${TDIR}"/usr/sbin/resume-boot \
		|| gen_die "Failed to copy '${GK_SHARE}/defaults/resume-boot.sh' to '${TDIR}/usr/sbin/resume-boot'"

	cp -a "${GK_SHARE}"/defaults/unlock-luks.sh "${TDIR}"/usr/sbin/unlock-luks \
		|| gen_die "Failed to copy '${GK_SHARE}/defaults/unlock-luks.sh' to '${TDIR}/usr/sbin/unlock-luks'"

	cp -aL "${ssh_authorized_keys_file}" "${TDIR}"/root/.ssh/ \
		|| gen_die "Failed to copy '${ssh_authorized_keys_file}'!"

	cp -aL /etc/localtime "${TDIR}"/etc/ \
		|| gen_die "Failed to copy '/etc/localtime'. Please set system's timezone!"

	echo "root:x:0:0:root:/root:/usr/bin/login-remote.sh" > "${TDIR}"/etc/passwd \
		|| gen_die "Failed to create '/etc/passwd'!"

	echo "/usr/bin/login-remote.sh" > "${TDIR}"/etc/shells \
		|| gen_die "Failed to create '/etc/shells'!"

	echo "root:!:0:0:99999:7:::" > "${TDIR}"/etc/shadow \
		|| gen_die "Failed to create '/etc/shadow'!"

	echo "root:x:0:root" > "${TDIR}"/etc/group \
		|| gen_die "Failed to create '/etc/group'!"

	chmod 0755 "${TDIR}"/usr/bin/login-remote.sh \
		|| gen_die "Failed to chmod of '${TDIR}/usr/bin/login-remote.sh'!"

	chmod 0755 "${TDIR}"/usr/sbin/resume-boot \
		|| gen_die "Failed to chmod of '${TDIR}/usr/sbin/resume-boot'!"

	chmod 0755 "${TDIR}"/usr/sbin/unlock-luks \
		|| gen_die "Failed to chmod of '${TDIR}/usr/sbin/unlock-luks'!"

	chmod 0640 "${TDIR}"/etc/shadow \
		|| gen_die "Failed to chmod of '${TDIR}/etc/shadow'!"

	chmod 0644 "${TDIR}"/etc/passwd \
		|| gen_die "Failed to chmod of '${TDIR}/etc/passwd'!"

	chmod 0644 "${TDIR}"/etc/group \
		|| gen_die "Failed to chmod of '${TDIR}/etc/group'!"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"
	log_future_cpio_content

	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append ${PN} to cpio!"
}

append_firmware() {
	if [ ! -d "${FIRMWARE_DIR}" ]
	then
		gen_die "specified firmware directory (${FIRMWARE_DIR}) does not exist"
	fi
	if [ -d "${TEMP}/initramfs-firmware-temp" ]
	then
		rm -r "${TEMP}/initramfs-firmware-temp/"
	fi
	mkdir -p "${TEMP}/initramfs-firmware-temp/lib/firmware"
	cd "${TEMP}/initramfs-firmware-temp"
	if [ -n "${FIRMWARE_FILES}" ]
	then
		pushd ${FIRMWARE_DIR} >/dev/null
		cp -rL --parents --target-directory="${TEMP}/initramfs-firmware-temp/lib/firmware/" ${FIRMWARE_FILES}
		popd >/dev/null
	else
		cp -a "${FIRMWARE_DIR}"/* ${TEMP}/initramfs-firmware-temp/lib/firmware/
	fi
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "appending firmware to cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-firmware-temp/"
}

append_gpg() {
	local PN=gnupg
	local TDIR="${TEMP}/initramfs-${PN}-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	populate_binpkg ${PN}

	mkdir -p "${TDIR}" || gen_die "Failed to create '${TDIR}'!"

	unpack "$(get_gkpkg_binpkg "${PN}")" "${TDIR}"

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append ${PN} to cpio!"
}

print_list()
{
	local x
	for x in ${*}
	do
		echo ${x}
	done
}

append_modules() {
	local group
	local group_modules
	local MOD_EXT="$(modules_kext)"

	if [ -d "${TEMP}/initramfs-modules-${KV}-temp" ]
	then
		rm -r "${TEMP}/initramfs-modules-${KV}-temp/"
	fi

	print_info 2 "$(getIndent 2)modules: >> Copying modules to initramfs..."
	if [ "${INSTALL_MOD_PATH}" != '' ]
	then
		cd ${INSTALL_MOD_PATH} || gen_die "Failed to chdir into '${INSTALL_MOD_PATH}'!"
	else
		cd / || gen_die "Failed to chdir into '/'!"
	fi

	local _MODULES_DIR="${PWD%/}/lib/modules/${KV}"
	if [ ! -d "${_MODULES_DIR}" ]
	then
		error_message="'${_MODULES_DIR}' does not exist! Did you forget"
		error_message+=" to compile kernel before building initramfs?"
		error_message+=" If you know what you are doing please set '--no-ramdisk-modules'."
		gen_die "${error_message}"
	fi

	mkdir -p "${TEMP}/initramfs-modules-${KV}-temp/lib/modules/${KV}"

	local n_copied_modules=0
	for i in `gen_dep_list`
	do
		mymod=`find "${_MODULES_DIR}" -name "${i}${MOD_EXT}" 2>/dev/null| head -n 1 `
		if [ -z "${mymod}" ]
		then
			print_warning 2 "$(getIndent 3) - ${i}${MOD_EXT} not found; skipping..."
			continue;
		fi

		print_info 2 "$(getIndent 3) - Copying ${i}${MOD_EXT}..."
		cp -ax --parents "${mymod}" "${TEMP}/initramfs-modules-${KV}-temp" ||
			gen_die "failed to copy '${mymod}' to '${TEMP}/initramfs-modules-${KV}-temp'"
		n_copied_modules=$[$n_copied_modules+1]
	done

	if [ ${n_copied_modules} -eq 0 ]
	then
		print_warning 1 "$(getIndent 2)modules: ${n_copied_modules} modules copied. Is that correct?"
	else
		print_info 2 "$(getIndent 2)modules: ${n_copied_modules} modules copied!"
	fi

	cp -ax --parents "${_MODULES_DIR}"/modules* ${TEMP}/initramfs-modules-${KV}-temp ||
		gen_die "failed to copy '${_MODULES_DIR}/modules*' to '${TEMP}/initramfs-modules-${KV}-temp'"

	mkdir -p "${TEMP}/initramfs-modules-${KV}-temp/etc/modules"
	for group_modules in ${!MODULES_*}; do
		group="$(echo $group_modules | cut -d_ -f2- | tr "[:upper:]" "[:lower:]")"
		print_list ${!group_modules} > "${TEMP}/initramfs-modules-${KV}-temp/etc/modules/${group}"
	done
	cd "${TEMP}/initramfs-modules-${KV}-temp/"
	log_future_cpio_content
	find . | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing modules cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-modules-${KV}-temp/"
}

append_modprobed() {
	local TDIR="${TEMP}/initramfs-modprobe.d-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}"
	fi

	mkdir -p "${TDIR}/etc"
	cp -r "/etc/modprobe.d" "${TDIR}/etc/modprobe.d"

	cd "${TDIR}"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing modprobe.d cpio"

	cd "${TEMP}"
	rm -rf "${TDIR}" > /dev/null
}

# check for static linked file with objdump
is_static() {
	LANG="C" LC_ALL="C" objdump -T $1 2>&1 | grep "not a dynamic object" > /dev/null
	return $?
}

append_auxilary() {
	local TDIR="${TEMP}/initramfs-aux-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}" || gen_die "Failed to clean out existing '${TDIR}'!"
	fi

	mkdir "${TDIR}" || gen_die "Failed to create '${TDIR}'!"
	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"

	local mydir=
	for mydir in \
		etc \
		sbin \
	; do
		mkdir -p "${TDIR}"/${mydir} || gen_die "Failed to create '${TDIR}/${mydir}'!"
	done

	local mylinuxrc=
	if [ -f "${CMD_LINUXRC}" ]
	then
		mylinuxrc="${CMD_LINUXRC}"
		print_info 2 "$(get_indent 2)>> Copying user specified linuxrc '${mylinuxrc}' to '/init' ..."
		cp -aL "${mylinuxrc}" "${TDIR}"/init 2>/dev/null \
			|| gen_die "Failed to copy '${mylinuxrc}' to '${TDIR}/init'!"
	elif isTrue "${NETBOOT}"
	then
		mylinuxrc="${GK_SHARE}/netboot/linuxrc.x"
		print_info 2 "$(get_indent 2)>> Copying netboot specific linuxrc '${mylinuxrc}' to '/init' ..."
		cp -aL "${mylinuxrc}" "${TDIR}"/init 2>/dev/null \
			|| gen_die "Failed to copy '${mylinuxrc}' to '${TDIR}/init'!"
	else
		if [ -f "${GK_SHARE}/arch/${ARCH}/linuxrc" ]
		then
			mylinuxrc="${GK_SHARE}/arch/${ARCH}/linuxrc"
		else
			mylinuxrc="${GK_SHARE}/defaults/linuxrc"
		fi

		print_info 2 "$(get_indent 2)>> Copying '${mylinuxrc}' to '/init' ..."
		cp -aL "${mylinuxrc}" "${TDIR}"/init 2>/dev/null \
			|| gen_die "Failed to copy '${mylinuxrc}' to '${TDIR}/init'!"
	fi

	# Make sure it's executable
	chmod 0755 "${TDIR}"/init || gen_die "Failed to chmod of '${TDIR}/init' to 0755!"

	# Make a symlink to init .. in case we are bundled inside the kernel as one
	# big cpio.
	pushd "${TDIR}" &>/dev/null || gen_die "Failed to chdir to '${TDIR}'!"
	ln -s init linuxrc || gen_die "Failed to create symlink 'linuxrc' to 'init'!"
	popd &>/dev/null || gen_die "Failed to chdir!"

	local myinitrd_script=
	if [ -f "${GK_SHARE}/arch/${ARCH}/initrd.scripts" ]
	then
		myinitrd_script="${GK_SHARE}/arch/${ARCH}/initrd.scripts"
	else
		myinitrd_script="${GK_SHARE}/defaults/initrd.scripts"
	fi
	print_info 2 "$(get_indent 2)>> Copying '${myinitrd_script}' to '/etc/initrd.scripts' ..."
	cp -aL "${myinitrd_script}" "${TDIR}"/etc/initrd.scripts 2>/dev/null \
		|| gen_die "Failed to copy '${myinitrd_script}' to '${TDIR}/etc/initrd.scripts'!"

	local myinitrd_default=
	if [ -f "${GK_SHARE}/arch/${ARCH}/initrd.defaults" ]
	then
		myinitrd_default="${GK_SHARE}/arch/${ARCH}/initrd.defaults"
	else
		myinitrd_default="${GK_SHARE}/defaults/initrd.defaults"
	fi
	print_info 2 "$(get_indent 2)>> Copying '${myinitrd_default}' to '/etc/initrd.defaults' ..."
	cp -aL "${myinitrd_default}" "${TDIR}"/etc/initrd.defaults 2>/dev/null \
		|| gen_die "Failed to copy '${myinitrd_default}' to '${TDIR}/etc/initrd.defaults'!"

	if [ -n "${REAL_ROOT}" ]
	then
		print_info 2 "$(get_indent 2)>> Setting REAL_ROOT to '${REAL_ROOT}' in '/etc/initrd.defaults' ..."
		sed -i "s:^REAL_ROOT=.*$:REAL_ROOT='${REAL_ROOT}':" \
			"${TDIR}"/etc/initrd.defaults \
			|| gen_die "Failed to set REAL_ROOT in '${TDIR}/etc/initrd.defaults'!"
	fi

	printf "%s" 'HWOPTS="$HWOPTS ' >> "${TDIR}"/etc/initrd.defaults \
		|| gen_die "Failed to add HWOPTS to '${TDIR}/etc/initrd.defaults'!"

	local group_modules group
	for group_modules in ${!MODULES_*}; do
		group="$(echo ${group_modules} | cut -d_ -f2 | tr "[:upper:]" "[:lower:]")"
		printf "%s" "${group} " >> "${TDIR}"/etc/initrd.defaults \
			|| gen_die "Failed to add MODULES_* to '${TDIR}/etc/initrd.defaults'!"
	done

	echo '"' >> "${TDIR}"/etc/initrd.defaults \
		|| gen_die "Failed to add closing '\"' to '${TDIR}/etc/initrd.defaults'!"

	if isTrue "${CMD_KEYMAP}"
	then
		print_info 2 "$(get_indent 2)>> Copying keymaps ..."
		mkdir -p "${TDIR}"/lib || gen_die "Failed to create '${TDIR}/lib'!"
		cp -R "${GK_SHARE}/defaults/keymaps" "${TDIR}"/lib/ 2>/dev/null \
			|| gen_die "Failed to copy '${GK_SHARE}/defaults/keymaps' to '${TDIR}/lib'!"

		if isTrue "${CMD_DOKEYMAPAUTO}"
		then
			print_info 2 "$(get_indent 2)>> Forcing keymap selection in initrd script due to DOKEYMAPAUTO setting ..."
			echo 'MY_HWOPTS="${MY_HWOPTS} keymap"' >> "${TDIR}"/etc/initrd.defaults \
				|| gen_die "Failed to add keymap to MY_HWOPTS in '${TDIR}/etc/initrd.defaults'!"
		fi
	fi

	pushd "${TDIR}"/sbin &>/dev/null || gen_die "Failed to chdir to '${TDIR}/sbin'!"
	ln -s ../init init || gen_die "Failed to create symlink 'init' to '../init'!"
	popd &>/dev/null || gen_die "Failed to chdir!"

	if isTrue "${NETBOOT}"
	then
		pushd "${GK_SHARE}/netboot/misc" &>/dev/null || gen_die "Failed to chdir to '${GK_SHARE}/netboot/misc'!"
		cp -pPRf * "${TDIR}"/ 2>/dev/null \
			|| gen_die "Failed to copy '${GK_SHARE}/netboot/misc' to '${TDIR}'!"
		popd &>/dev/null || gen_die "Failed to chdir!"
	fi

	cd "${TDIR}" || gen_die "Failed to chdir to '${TDIR}'!"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "Failed to append auxilary to cpio!"
}

append_data() {
	local name=$1 var=$2
	local func="append_${name}"

	[ $# -eq 0 ] && gen_die "append_data() called with zero arguments"
	if [ $# -eq 1 ] || isTrue "${var}"
	then
		print_info 1 "$(get_indent 1)>> Appending ${name} cpio data ..."
		${func} || gen_die "${func}() failed!"
	fi
}

create_initramfs() {
	local lddtree_testfile=`which cpio 2>/dev/null`
	if [[ -z "${lddtree_testfile}" || ! -e "${lddtree_testfile}" ]]; then
		print_warning 1 "cpio binary not found -- cannot check if lddtree is working!"
	elif ! lddtree "${lddtree_testfile}" 1>/dev/null 2>&1; then
		gen_die "'lddtree ${lddtree_testfile}' failed -- cannot generate initramfs without working lddtree!"
	fi

	local compress_ext=""
	print_info 1 "initramfs: >> Initializing..."

	# Create empty cpio
	CPIO="${TMPDIR}/initramfs-${KV}"
	append_data 'devices' # WARNING, must be first!
	append_data 'base_layout'
	append_data 'auxilary' "${BUSYBOX}"
	append_data 'busybox' "${BUSYBOX}"
	isTrue "${CMD_E2FSPROGS}" && append_data 'e2fsprogs'
	append_data 'lvm' "${LVM}"
	append_data 'dmraid' "${DMRAID}"
	append_data 'iscsi' "${ISCSI}"
	append_data 'mdadm' "${MDADM}"
	append_data 'luks' "${LUKS}"
	append_data 'dropbear' "${SSH}"
	append_data 'multipath' "${MULTIPATH}"
	append_data 'gpg' "${GPG}"

	if isTrue "${RAMDISKMODULES}"
	then
		append_data 'modules'
	else
		print_info 1 "initramfs: Not copying modules..."
	fi

	append_data 'zfs' "${ZFS}"

	append_data 'btrfs' "${BTRFS}"

	append_data 'blkid' "${DISKLABEL}"

	append_data 'unionfs_fuse' "${UNIONFS}"

	append_data 'splash' "${SPLASH}"

	append_data 'modprobed'

	if isTrue "${ZFS}" || isTrue "${LUKS}"
	then
		append_data 'libgcc_s'
	fi

	if isTrue "${FIRMWARE}" && [ -n "${FIRMWARE_DIR}" ]
	then
		append_data 'firmware'
	fi

	# This should always be appended last
	if [ "${INITRAMFS_OVERLAY}" != '' ]
	then
		append_data 'overlay'
	fi

	if [ -f "${TEMP}/.binaries_copied" ]
	then
		append_data 'linker'
	else
		print_info 2 "initramfs: Not appending linker because no binaries have been copied ..."
	fi

	# Finalize cpio by removing duplicate files
	# TODO: maybe replace this with:
	# http://search.cpan.org/~pixel/Archive-Cpio-0.07/lib/Archive/Cpio.pm
	# as then we can dedupe ourselves...
	if [[ $UID -eq 0 ]]; then
		print_info 1 "$(getIndent 1)>> Deduping cpio..."
		local TDIR="${TEMP}/initramfs-final"
		mkdir -p "${TDIR}"
		cd "${TDIR}"

		cpio --quiet -i -F "${CPIO}" 2> /dev/null \
			|| gen_die "extracting cpio for dedupe"
		find . -print | cpio ${CPIO_ARGS} -F "${CPIO}" 2>/dev/null \
			|| gen_die "rebuilding cpio for dedupe"
		cd "${TEMP}"
		rm -rf "${TDIR}"
	else
		print_info 1 "$(getIndent 1)>> Cannot deduping cpio contents without root; skipping"
	fi

	cd "${TEMP}"

	# NOTE: We do not work with ${KERNEL_CONFIG} here, since things like
	#       "make oldconfig" or --noclean could be in effect.
	if [ -f "${KERNEL_OUTPUTDIR}"/.config ]; then
		local ACTUAL_KERNEL_CONFIG="${KERNEL_OUTPUTDIR}"/.config
	else
		local ACTUAL_KERNEL_CONFIG="${KERNEL_CONFIG}"
	fi

	if [[ "$(file --brief --mime-type "${ACTUAL_KERNEL_CONFIG}")" == application/x-gzip ]]; then
		# Support --kernel-config=/proc/config.gz, mainly
		local CONFGREP=zgrep
	else
		local CONFGREP=grep
	fi

	if isTrue "${INTEGRATED_INITRAMFS}"
	then
		# Explicitly do not compress if we are integrating into the kernel.
		# The kernel will do a better job of it than us.
		mv ${TMPDIR}/initramfs-${KV} ${TMPDIR}/initramfs-${KV}.cpio
		sed -i '/^.*CONFIG_INITRAMFS_SOURCE=.*$/d' "${KERNEL_OUTPUTDIR}/.config" ||
			gen_die "failed to delete CONFIG_INITRAMFS_SOURCE from '${KERNEL_OUTPUTDIR}/.config'"

		compress_config='INITRAMFS_COMPRESSION_NONE'
		case ${compress_ext} in
			gz)   compress_config='INITRAMFS_COMPRESSION_GZIP' ;;
			bz2)  compress_config='INITRAMFS_COMPRESSION_BZIP2' ;;
			lzma) compress_config='INITRAMFS_COMPRESSION_LZMA' ;;
			xz)   compress_config='INITRAMFS_COMPRESSION_XZ' ;;
			lzo)  compress_config='INITRAMFS_COMPRESSION_LZO' ;;
			lz4)  compress_config='INITRAMFS_COMPRESSION_LZ4' ;;
			*)    compress_config='INITRAMFS_COMPRESSION_NONE' ;;
		esac
		# All N default except XZ, so there it gets used if the kernel does
		# compression on it's own.
		cat >>${KERNEL_OUTPUTDIR}/.config	<<-EOF
		CONFIG_INITRAMFS_SOURCE="${TMPDIR}/initramfs-${KV}.cpio${compress_ext}"
		CONFIG_INITRAMFS_ROOT_UID=0
		CONFIG_INITRAMFS_ROOT_GID=0
		CONFIG_INITRAMFS_COMPRESSION_NONE=n
		CONFIG_INITRAMFS_COMPRESSION_GZIP=n
		CONFIG_INITRAMFS_COMPRESSION_BZIP2=n
		CONFIG_INITRAMFS_COMPRESSION_LZMA=n
		CONFIG_INITRAMFS_COMPRESSION_XZ=y
		CONFIG_INITRAMFS_COMPRESSION_LZO=n
		CONFIG_INITRAMFS_COMPRESSION_LZ4=n
		CONFIG_${compress_config}=y
		EOF
	else
		if isTrue "${COMPRESS_INITRD}"
		then
			cmd_xz=$(type -p xz)
			cmd_lzma=$(type -p lzma)
			cmd_bzip2=$(type -p bzip2)
			cmd_gzip=$(type -p gzip)
			cmd_lzop=$(type -p lzop)
			cmd_lz4=$(type -p lz4)
			pkg_xz='app-arch/xz-utils'
			pkg_lzma='app-arch/xz-utils'
			pkg_bzip2='app-arch/bzip2'
			pkg_gzip='app-arch/gzip'
			pkg_lzop='app-arch/lzop'
			pkg_lz4='app-arch/lz4'
			local compression
			case ${COMPRESS_INITRD_TYPE} in
				xz|lzma|bzip2|gzip|lzop|lz4) compression=${COMPRESS_INITRD_TYPE} ;;
				lzo) compression=lzop ;;
				best|fastest)
					for tuple in \
							'CONFIG_RD_XZ    cmd_xz    xz' \
							'CONFIG_RD_LZMA  cmd_lzma  lzma' \
							'CONFIG_RD_BZIP2 cmd_bzip2 bzip2' \
							'CONFIG_RD_GZIP  cmd_gzip  gzip' \
							'CONFIG_RD_LZO   cmd_lzop  lzop' \
							'CONFIG_RD_LZ4   cmd_lz4   lz4' \
							; do
						set -- ${tuple}
						kernel_option=$1
						cmd_variable_name=$2
						if ${CONFGREP} -q "^${kernel_option}=y" "${ACTUAL_KERNEL_CONFIG}" && test -n "${!cmd_variable_name}" ; then
							compression=$3
							[[ ${COMPRESS_INITRD_TYPE} == best ]] && break
						fi
					done
					[[ -z "${compression}" ]] && gen_die "None of the initramfs compression methods we tried are supported by your kernel (config file \"${ACTUAL_KERNEL_CONFIG}\"), strange!?"
					;;
				*)
					gen_die "Compression '${COMPRESS_INITRD_TYPE}' unknown"
					;;
			esac

			# Check for actual availability
			cmd_variable_name=cmd_${compression}
			pkg_variable_name=pkg_${compression}
			[[ -z "${!cmd_variable_name}" ]] && gen_die "Compression '${compression}' is not available. Please install package '${!pkg_variable_name}'."

			case $compression in
				xz) compress_ext='.xz' compress_cmd="${cmd_xz} -e --check=none -z -f -9" ;;
				lzma) compress_ext='.lzma' compress_cmd="${cmd_lzma} -z -f -9" ;;
				bzip2) compress_ext='.bz2' compress_cmd="${cmd_bzip2} -z -f -9" ;;
				gzip) compress_ext='.gz' compress_cmd="${cmd_gzip} -f -9" ;;
				lzop) compress_ext='.lzo' compress_cmd="${cmd_lzop} -f -9" ;;
				lz4) compress_ext='.lz4' compress_cmd="${cmd_lz4} -f -9 -l -q" ;;
			esac

			if [ -n "${compression}" ]; then
				print_info 1 "$(getIndent 1)>> Compressing cpio data (${compress_ext})..."
				print_info 5 "$(getIndent 1)>> Compression command (${compress_cmd} $CPIO)..."
				${compress_cmd} "${CPIO}" || gen_die "Compression (${compress_cmd}) failed"
				mv -f "${CPIO}${compress_ext}" "${CPIO}" || gen_die "Rename failed"
			else
				print_info 1 "$(getIndent 1)>> Not compressing cpio data ..."
			fi
		fi

		## To early load microcode we need to follow some pretty specific steps
		## mostly laid out in linux/Documentation/x86/early-microcode.txt
		## It only loads monolithic ucode from an uncompressed cpio, which MUST
		## be before the other cpio archives in the stream.
		cfg_CONFIG_MICROCODE=$(kconfig_get_opt "${KERNEL_OUTPUTDIR}"/.config CONFIG_MICROCODE)
		if isTrue "${MICROCODE_INITRAMFS}" && [ "${cfg_CONFIG_MICROCODE}" == "y" ]; then
			if [[ "${MICROCODE}" == intel ]]; then
				# Only show this information for Intel users because we have no mechanism yet
				# to generate amd-*.img in /boot after sys-kernel/linux-firmware update
				print_info 1 "MICROCODE_INITRAMFS option is enabled by default for compatability but made obsolete by >=sys-boot/grub-2.02-r1"
			fi

			cfg_CONFIG_MICROCODE_INTEL=$(kconfig_get_opt "${KERNEL_OUTPUTDIR}"/.config CONFIG_MICROCODE_INTEL)
			cfg_CONFIG_MICROCODE_AMD=$(kconfig_get_opt "${KERNEL_OUTPUTDIR}"/.config CONFIG_MICROCODE_AMD)
			print_info 1 "$(getIndent 1)>> Adding early-microcode support..."
			UCODEDIR="${TEMP}/ucode_tmp/kernel/x86/microcode/"
			mkdir -p "${UCODEDIR}"
			if [ "${cfg_CONFIG_MICROCODE_INTEL}" == "y" ]; then
				if [ -d /lib/firmware/intel-ucode ]; then
					print_info 1 "$(getIndent 2)early-microcode: Adding GenuineIntel.bin..."
					cat /lib/firmware/intel-ucode/* > "${UCODEDIR}/GenuineIntel.bin" || gen_die "Failed to concat intel cpu ucode"
				else
					print_info 1 "$(getIndent 2)early-microcode: CONFIG_MICROCODE_INTEL=y set but no ucode available. Please install sys-firmware/intel-microcode[split-ucode]"
				fi
			fi
			if [ "${cfg_CONFIG_MICROCODE_AMD}" == "y" ]; then
				if [ -d /lib/firmware/amd-ucode ]; then
					print_info 1 "$(getIndent 2)early-microcode: Adding AuthenticAMD.bin..."
					cat /lib/firmware/amd-ucode/*.bin > "${UCODEDIR}/AuthenticAMD.bin" || gen_dir "Failed to concat amd cpu ucode"
				else
					print_info 1 "$(getIndent 2)early-microcode: CONFIG_MICROCODE_AMD=y set but no ucode available. Please install sys-firmware/linux-firmware"
				fi
			fi
			if [ -f "${UCODEDIR}/AuthenticAMD.bin" -o -f "${UCODEDIR}/GenuineIntel.bin" ]; then
				print_info 1 "$(getIndent 2)early-microcode: Creating cpio..."
				pushd "${TEMP}/ucode_tmp" > /dev/null
				find . | cpio -o -H newc > ../ucode.cpio || gen_die "Failed to create cpu microcode cpio"
				popd > /dev/null
				print_info 1 "$(getIndent 2)early-microcode: Prepending early-microcode to initramfs..."
				cat "${TEMP}/ucode.cpio" "${CPIO}" > "${CPIO}.early-microcode" || gen_die "Failed to prepend early-microcode to initramfs"
				mv -f "${CPIO}.early-microcode" "${CPIO}" || gen_die "Rename failed"
			else
				print_info 1 "$(getIndent 2)early-microcode: CONFIG_MICROCODE=y is set but no microcode found"
				print_info 1 "$(getIndent 2)early-microcode: You can disable MICROCODE_INITRAMFS option if you use your bootloader to load AMD/Intel ucode initrd"
			fi
		fi
		if isTrue "${WRAP_INITRD}"
		then
			local mkimage_cmd=$(type -p mkimage)
			[[ -z ${mkimage_cmd} ]] && gen_die "mkimage is not available. Please install package 'dev-embedded/u-boot-tools'."
			local mkimage_args="-A ${ARCH} -O linux -T ramdisk -C ${compression:-none} -a 0x00000000 -e 0x00000000"
			print_info 1 "$(getIndent 1)>> Wrapping initramfs using mkimage..."
			print_info 2 "$(getIndent 1)${mkimage_cmd} ${mkimage_args} -n initramfs-${KV} -d ${CPIO} ${CPIO}.uboot"
			${mkimage_cmd} ${mkimage_args} -n "initramfs-${KV}" -d "${CPIO}" "${CPIO}.uboot" >> ${LOGFILE} 2>&1 || gen_die "Wrapping initramfs using mkimage failed"
			mv -f "${CPIO}.uboot" "${CPIO}" || gen_die "Rename failed"
		fi
	fi

	if isTrue "${CMD_INSTALL}"
	then
		if ! isTrue "${INTEGRATED_INITRAMFS}"
		then
			copy_image_with_preserve "initramfs" \
				"${TMPDIR}/initramfs-${KV}" \
				"initramfs-${KNAME}-${ARCH}-${KV}"
		fi
	fi
}
