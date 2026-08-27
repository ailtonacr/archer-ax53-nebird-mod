#!/bin/sh
# Copyright (C) 2006-2013 OpenWrt.org
# Copyright (C) 2010 Vertical Communications

mount() {
	/bin/busybox mount -o noatime "$@"
}

boot_hook_splice_start() {
	export -n PI_HOOK_SPLICE=1
}

boot_hook_splice_finish() {
	local hook
	for hook in $PI_STACK_LIST; do
		local v; eval "v=\${${hook}_splice:+\$${hook}_splice }$hook"
		export -n "${hook}=${v% }"
		export -n "${hook}_splice="
	done
	export -n PI_HOOK_SPLICE=
}

boot_hook_init() {
	local hook="${1}_hook"
	export -n "PI_STACK_LIST=${PI_STACK_LIST:+$PI_STACK_LIST }$hook"
	export -n "$hook="
}

boot_hook_add() {
	local hook="${1}_hook${PI_HOOK_SPLICE:+_splice}"
	local func="${2}"

	[ -n "$func" ] && {
		local v; eval "v=\$$hook"
		export -n "$hook=${v:+$v }$func"
	}
}

boot_hook_shift() {
	local hook="${1}_hook"
	local rvar="${2}"

	local v; eval "v=\$$hook"
	[ -n "$v" ] && {
		local first="${v%% *}"

		[ "$v" != "${v#* }" ] && \
			export -n "$hook=${v#* }" || \
			export -n "$hook="

		export -n "$rvar=$first"
		return 0
	}

	return 1
}

boot_run_hook() {
	local hook="$1"
	local func

	while boot_hook_shift "$hook" func; do
		local ran; eval "ran=\$PI_RAN_$func"
		[ -n "$ran" ] || {
			export -n "PI_RAN_$func=1"
			$func "$1" "$2"
		}
	done
}

pivot() { # <new_root> <old_root>
	mount -o move /proc $1/proc && \
	pivot_root $1 $1$2 && {
		mount -o move $2/dev /dev
		mount -o move $2/tmp /tmp
		mount -o move $2/sys /sys 2>&-
		mount -o move $2/overlay /overlay 2>&-
		mount -o move $2/mnt /mnt 2>&-
		return 0
	}
}

fopivot() { # <rw_root> <work_dir> <ro_root> <dupe?>
	root=$1
	{
		if grep -q overlay /proc/filesystems; then
			# mount -t overlayfs -olowerdir=/,upperdir=$1 "overlayfs:$1" /mnt && root=/mnt
			mount -o lowerdir=/,upperdir=$4,workdir=$5 -t overlay "overlayfs:$1" /mnt && root=/mnt
		elif grep -q mini_fo /proc/filesystems; then
			mount -t mini_fo -o base=/,sto=$1 "mini_fo:$1" /mnt 2>&- && root=/mnt
		else
			mount --bind / /mnt
			mount --bind -o union "$1" /mnt && root=/mnt
		fi
	} || {
		[ "$3" = "1" ] && {
		mount | grep "on $1 type" 2>&- 1>&- || mount -o bind $1 $1
		}
	}
	pivot $root $2
}

ramoverlay() {
	mount -t tmpfs -o mode=0755 root /mnt
	mount -t tmpfs -o mode=0755 root /overlay
	mkdir -p /overlay/upper
	mkdir -p /overlay/worker
	fopivot /overlay /rom 1 /overlay/upper /overlay/worker
}
