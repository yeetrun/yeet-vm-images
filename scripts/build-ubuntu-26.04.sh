#!/usr/bin/env bash
# Copyright (c) 2025 AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.
# shellcheck disable=SC2016 # Literal package metadata and Perl config expressions.

set -euo pipefail

profile="${YEET_VM_IMAGE_PROFILE:-fast}"
guest_base_id="${YEET_VM_GUEST_BASE_ID:-}"
out_dir="${1:-dist/$guest_base_id}"
work_dir="${YEET_VM_IMAGE_WORK_DIR:-}"
kernel_release="${YEET_VM_KERNEL_RELEASE_ID:-}"
kernel_manifest_sha256="${YEET_VM_KERNEL_MANIFEST_SHA256:-}"
guest_init_path="${YEET_VM_INIT_PATH:-}"
guest_agent_path="${YEET_VM_AGENT_PATH:-}"
yeet_source_rev="${YEET_SOURCE_REV:-}"
images_source_rev="${YEET_VM_IMAGES_SOURCE_REV:-}"
workflow_run_url="${YEET_VM_WORKFLOW_RUN_URL:-}"
script_source="${BASH_SOURCE[0]}"
script_dir="${script_source%/*}"
if [ "$script_dir" = "$script_source" ]; then
	script_dir="."
fi
script_dir="$(cd "$script_dir" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
ghostty_terminfo_source="${YEET_VM_GHOSTTY_TERMINFO:-$repo_root/assets/xterm-ghostty.terminfo}"

ubuntu_base_url="${UBUNTU_CLOUD_BASE_URL:-https://cloud-images.ubuntu.com/resolute/current}"
ubuntu_image="${UBUNTU_CLOUD_IMAGE:-resolute-server-cloudimg-amd64.tar.gz}"
zstd_level="${ZSTD_LEVEL:-10}"
yeet_vm_kernel_apt_uri="${YEET_VM_KERNEL_APT_URI:-https://yeetrun.github.io/yeet-vm-images/apt}"
yeet_vm_kernel_apt_keyring_url="${YEET_VM_KERNEL_APT_KEYRING_URL:-${yeet_vm_kernel_apt_uri}/yeet-vm-kernel-archive-keyring.gpg}"

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

for cmd in awk cat chmod cmp cp curl date debugfs dirname find grep install jq mkdir mktemp rm sha256sum stat tar zstd; do
	require "$cmd"
done

if [ "$profile" != "fast" ]; then
	echo "unsupported YEET_VM_IMAGE_PROFILE=$profile (component guest bases require fast)" >&2
	exit 1
fi
for cmd in chroot dumpe2fs e2fsck id infocmp mount mountpoint tic tune2fs umount; do
	require "$cmd"
done
if ! [[ "$guest_base_id" =~ ^guest-ubuntu-26[.]04-amd64-v[1-9][0-9]*$ ]]; then
	echo "YEET_VM_GUEST_BASE_ID must be guest-ubuntu-26.04-amd64-vN: $guest_base_id" >&2
	exit 1
fi
if ! [[ "$kernel_release" =~ ^kernel-linux-([0-9]+[.][0-9]+([.][0-9]+)*)-yeet-v([1-9][0-9]*)$ ]]; then
	echo "YEET_VM_KERNEL_RELEASE_ID must be an immutable kernel release: $kernel_release" >&2
	exit 1
fi
kernel_upstream_version="${BASH_REMATCH[1]}"
kernel_packaging_revision="${BASH_REMATCH[3]}"
kernel_version="linux-${kernel_upstream_version}-yeet"
if ! [[ "$kernel_manifest_sha256" =~ ^[0-9a-f]{64}$ ]]; then
	echo "YEET_VM_KERNEL_MANIFEST_SHA256 must be a lowercase SHA-256" >&2
	exit 1
fi
for revision in "$yeet_source_rev" "$images_source_rev"; do
	if ! [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
		echo "source revisions must be 40-character lowercase Git revisions" >&2
		exit 1
	fi
done
if ! [[ "$workflow_run_url" =~ ^https://github[.]com/yeetrun/yeet-vm-images/actions/runs/[1-9][0-9]*$ ]]; then
	echo "YEET_VM_WORKFLOW_RUN_URL must identify a yeet-vm-images Actions run" >&2
	exit 1
fi
if [ -z "$guest_init_path" ]; then
	echo "YEET_VM_INIT_PATH is required for the fast profile" >&2
	exit 1
fi
if [ ! -x "$guest_init_path" ]; then
	echo "YEET_VM_INIT_PATH is not executable: $guest_init_path" >&2
	exit 1
fi
if [ -z "$guest_agent_path" ]; then
	echo "YEET_VM_AGENT_PATH is required for the fast profile" >&2
	exit 1
fi
if [ ! -x "$guest_agent_path" ]; then
	echo "YEET_VM_AGENT_PATH is not executable: $guest_agent_path" >&2
	exit 1
fi
if [ ! -r "$ghostty_terminfo_source" ]; then
	echo "YEET_VM_GHOSTTY_TERMINFO is not readable: $ghostty_terminfo_source" >&2
	exit 1
fi
if [ "$(id -u)" != 0 ]; then
	echo "the fast profile must run as root so it can mount and customize the rootfs" >&2
	exit 1
fi

if [ -z "$work_dir" ]; then
	work_dir="$(mktemp -d)"
	cleanup_work=1
else
	mkdir -p "$work_dir"
	cleanup_work=0
fi

rootfs_mount=""
cleanup_rootfs_mount() {
	if [ -z "$rootfs_mount" ]; then
		return
	fi
	for rel in run sys proc dev; do
		if mountpoint -q "$rootfs_mount/$rel" 2>/dev/null; then
			umount "$rootfs_mount/$rel" || true
		fi
	done
	if mountpoint -q "$rootfs_mount" 2>/dev/null; then
		umount "$rootfs_mount" || true
	fi
}

cleanup() {
	cleanup_rootfs_mount
	if [ "${cleanup_work:-0}" = 1 ]; then
		rm -rf "$work_dir"
	fi
}
trap cleanup EXIT

mkdir -p "$out_dir"
if [ -n "$(find "$out_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
	echo "guest-base output directory must be empty: $out_dir" >&2
	exit 1
fi

echo "Downloading Ubuntu cloud image..."
curl -fL --retry 3 -o "$work_dir/$ubuntu_image" "$ubuntu_base_url/$ubuntu_image"
curl -fsSL --retry 3 -o "$work_dir/SHA256SUMS" "$ubuntu_base_url/SHA256SUMS"

expected_image_sha="$(awk -v image="$ubuntu_image" '$2 == "*" image || $2 == image { print $1; exit }' "$work_dir/SHA256SUMS")"
if [ -z "$expected_image_sha" ]; then
	echo "could not find $ubuntu_image in $ubuntu_base_url/SHA256SUMS" >&2
	exit 1
fi
actual_image_sha="$(sha256sum "$work_dir/$ubuntu_image" | awk '{ print $1 }')"
if [ "$actual_image_sha" != "$expected_image_sha" ]; then
	echo "Ubuntu cloud image checksum mismatch: got $actual_image_sha, want $expected_image_sha" >&2
	exit 1
fi

echo "Extracting Ubuntu rootfs image..."
tar xzf "$work_dir/$ubuntu_image" -C "$work_dir"
rootfs_source="$(find "$work_dir" -maxdepth 1 -name '*.img' -type f -print -quit)"
if [ -z "$rootfs_source" ]; then
	echo "Ubuntu cloud image tarball did not contain an .img file" >&2
	exit 1
fi

write_fast_rootfs_policy_files() {
	local root="$1"
	install -d -m 0755 \
		"$root/etc/apt/keyrings" \
		"$root/etc/apt/preferences.d" \
		"$root/etc/apt/sources.list.d" \
		"$root/etc/needrestart/conf.d" \
		"$root/etc/sysctl.d" \
		"$root/etc/tmpfiles.d" \
		"$root/usr/share/doc/yeet-vm-image"
	curl -fsSL --retry 3 -o "$root/etc/apt/keyrings/yeet-vm-kernel-archive-keyring.gpg" "$yeet_vm_kernel_apt_keyring_url"
	chmod 0644 "$root/etc/apt/keyrings/yeet-vm-kernel-archive-keyring.gpg"
	cat >"$root/etc/apt/sources.list.d/yeet-vm-kernel.sources" <<EOF
Types: deb
URIs: $yeet_vm_kernel_apt_uri
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/yeet-vm-kernel-archive-keyring.gpg
EOF
	cat >"$root/etc/apt/preferences.d/99-yeet-managed-kernel" <<'EOF'
Package: linux-image-* linux-modules-* linux-modules-extra-* linux-headers-* linux-generic* linux-virtual* grub-* shim-signed initramfs-tools initramfs-tools-* snapd snap-confine squashfs-tools
Pin: version *
Pin-Priority: -1
EOF
	cat >"$root/etc/needrestart/conf.d/99-yeet-vm-kernel.conf" <<'EOF'
# Yeet VMs boot a host-managed kernel selected through data-only guest metadata,
# not a guest-managed Ubuntu linux-image package. Keep needrestart service
# checks, but skip kernel package hints that cannot apply in this guest.
$nrconf{kernelhints} = 0;
EOF
	cat >"$root/usr/share/doc/yeet-vm-image/kernel.md" <<'EOF'
# Yeet VM Kernel

This guest base boots with a host-managed Firecracker kernel. The
`yeet-vm-kernel` package writes a data-only request identifying an immutable
kernel release and manifest digest; the untrusted guest never supplies the host
artifact itself.

Guest apt upgrades intentionally do not install Ubuntu kernel, bootloader, or
initramfs packages. Reboot after a `yeet-vm-kernel` package update so Catch can
validate the request against its trusted kernel catalog and apply it.

The fast yeet VM image profile intentionally does not support loadable kernel
modules or snap packages. Router-oriented kernel features such as TUN,
netfilter, conntrack, nftables, nft NAT/masquerade, and Ubuntu iptables-nft
compatibility are built into the yeet-managed kernel instead of loaded from
guest module packages.
EOF
	cat >"$root/usr/share/doc/yeet-vm-image/init.md" <<'EOF'
# Yeet VM Init

Fast yeet VM images boot through `/usr/local/lib/yeet-vm/yeet-init`.
The init shim performs small pre-systemd setup, reports the first kernel
configured IPv4 address on the serial console, and then execs systemd as PID 1.

SSH remains managed by systemd through `yeet-sshd.service`; `yeet run` waits for
the systemd-backed `yeet-guest-ready.service` marker before returning.
EOF
	cat >"$root/etc/sysctl.d/99-yeet-vm-router.conf" <<'EOF'
# Yeet VMs should be ready to run guest-managed routers and exit nodes.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
	cat >"$root/etc/tmpfiles.d/yeet-vm-tun.conf" <<'EOF'
d /dev/net 0755 root root -
c /dev/net/tun 0666 root root 10:200
EOF
}

install_fast_rootfs_terminfo() {
	local root="$1"
	install -d -m 0755 "$root/etc/terminfo"
	tic -x -o "$root/etc/terminfo" "$ghostty_terminfo_source"
	TERMINFO="$root/etc/terminfo" infocmp -x xterm-ghostty >/dev/null
}

validate_fast_rootfs_ubuntu_compatibility() {
	local root="$1"

	if [ -L "$root/usr/sbin" ] || [ ! -d "$root/usr/sbin" ]; then
		echo "/usr/sbin must remain an Ubuntu-owned directory" >&2
		exit 1
	fi

	local sbin_target
	sbin_target="$(chroot "$root" /usr/bin/readlink /sbin 2>/dev/null || true)"
	if [ "$sbin_target" != "usr/sbin" ]; then
		echo "/sbin must keep Ubuntu cloud image target usr/sbin, got ${sbin_target:-missing}" >&2
		exit 1
	fi

	for path in \
		/usr/sbin/sshd \
		/usr/sbin/agetty \
		/usr/sbin/unix_chkpwd \
		/usr/sbin/iptables-nft \
		/usr/sbin/xtables-nft-multi
	do
		if [ ! -e "$root$path" ]; then
			echo "missing Ubuntu package-owned path $path" >&2
			exit 1
		fi
	done

	for path in \
		/usr/sbin/sshd \
		/usr/sbin/agetty \
		/usr/sbin/unix_chkpwd \
		/usr/sbin/iptables-nft \
		/usr/sbin/xtables-nft-multi
	do
		if ! chroot "$root" /usr/bin/dpkg -S "$path" >/dev/null; then
			echo "dpkg ownership missing for $path" >&2
			exit 1
		fi
	done

	chroot "$root" /usr/bin/dpkg -S /usr/sbin/sshd >/dev/null
	chroot "$root" /usr/bin/update-alternatives --display iptables >/dev/null

	for path in /usr/sbin/iptables /usr/sbin/iptables-restore /usr/sbin/iptables-save; do
		local target
		target="$(chroot "$root" /usr/bin/readlink -f "$path" 2>/dev/null || true)"
		if [ -z "$target" ] || [ ! -e "$root$target" ]; then
			echo "iptables alternative $path resolves to missing target ${target:-missing}" >&2
			exit 1
		fi
	done

	if ! chroot "$root" /usr/sbin/iptables --version | grep -q 'nf_tables'; then
		echo "iptables must use the nf_tables backend" >&2
		exit 1
	fi
	chroot "$root" /usr/bin/rsync --version >/dev/null

	if [ ! -e "$root/etc/needrestart/conf.d/99-yeet-vm-kernel.conf" ]; then
		echo "missing yeet needrestart kernel policy" >&2
		exit 1
	fi
	if ! grep -Fxq '$nrconf{kernelhints} = 0;' "$root/etc/needrestart/conf.d/99-yeet-vm-kernel.conf"; then
		echo "needrestart kernel hints must be disabled for yeet-managed guest kernels" >&2
		exit 1
	fi

	if [ ! -s "$root/etc/apt/keyrings/yeet-vm-kernel-archive-keyring.gpg" ]; then
		echo "missing yeet VM kernel apt keyring" >&2
		exit 1
	fi
	if [ ! -e "$root/etc/apt/sources.list.d/yeet-vm-kernel.sources" ]; then
		echo "missing yeet VM kernel apt source" >&2
		exit 1
	fi
	if ! grep -Fxq "URIs: $yeet_vm_kernel_apt_uri" "$root/etc/apt/sources.list.d/yeet-vm-kernel.sources"; then
		echo "yeet VM kernel apt source must use $yeet_vm_kernel_apt_uri" >&2
		exit 1
	fi

	local expected_kernel_package_version
	expected_kernel_package_version="${kernel_upstream_version}-${kernel_packaging_revision}"
	local installed_kernel_package_version
	installed_kernel_package_version="$(chroot "$root" /usr/bin/dpkg-query -W -f='${Version}' yeet-vm-kernel 2>/dev/null || true)"
	if [ "$installed_kernel_package_version" != "$expected_kernel_package_version" ]; then
		echo "yeet-vm-kernel package version mismatch: installed=${installed_kernel_package_version:-missing} expected=$expected_kernel_package_version" >&2
		exit 1
	fi
	if [ ! -s "$root/etc/yeet-vm/kernel/selected.json" ]; then
		echo "missing yeet VM selected kernel metadata" >&2
		exit 1
	fi
	jq -e \
		--arg version "$kernel_version" \
		--arg release "$kernel_release" \
		--arg manifest "$kernel_manifest_sha256" '
		.schema_version == 2 and
		.version == $version and
		.release_id == $release and
		.manifest_sha256 == $manifest and
		.kernel == ("/usr/lib/yeet-vm/kernels/" + $version + "/vmlinux") and
		.kernel_config == ("/usr/lib/yeet-vm/kernels/" + $version + "/kernel.config") and
		(.sha256.vmlinux | test("^[0-9a-f]{64}$")) and
		(.sha256["kernel.config"] | test("^[0-9a-f]{64}$"))
	' "$root/etc/yeet-vm/kernel/selected.json" >/dev/null || {
		echo "selected kernel metadata does not match the requested immutable kernel" >&2
		exit 1
	}
}

run_fast_rootfs_e2fsck() {
	local rootfs="$1"
	local status

	set +e
	e2fsck -fy "$rootfs"
	status=$?
	set -e

	case "$status" in
	0 | 1)
		;;
	*)
		echo "e2fsck failed after rootfs feature normalization: exit $status" >&2
		exit "$status"
		;;
	esac
}

normalize_fast_rootfs_ext4_features() {
	local rootfs="$1"
	local features

	features="$(dumpe2fs -h "$rootfs" 2>/dev/null | awk -F: '/Filesystem features/ { print $2; exit }')"
	if printf '%s\n' "$features" | grep -qw orphan_file; then
		echo "Disabling ext4 orphan_file for LTS host e2fsprogs compatibility..."
		tune2fs -O ^orphan_file "$rootfs" >/dev/null
		run_fast_rootfs_e2fsck "$rootfs"
	fi

	features="$(dumpe2fs -h "$rootfs" 2>/dev/null | awk -F: '/Filesystem features/ { print $2; exit }')"
	if printf '%s\n' "$features" | grep -Eq '(^|[[:space:]])orphan_file($|[[:space:]])|(^|[[:space:]])FEATURE_'; then
		echo "rootfs ext4 features are not compatible with LTS host tooling: $features" >&2
		exit 1
	fi
}

customize_fast_rootfs() {
	local rootfs="$1"
	rootfs_mount="$work_dir/rootfs-mount"
	mkdir -p "$rootfs_mount"

	echo "Customizing rootfs for yeet-managed kernel policy..."
	mount -o loop,rw "$rootfs" "$rootfs_mount"
	for rel in dev proc sys run; do
		mkdir -p "$rootfs_mount/$rel"
	done
	mount --bind /dev "$rootfs_mount/dev"
	mount -t proc proc "$rootfs_mount/proc"
	mount -t sysfs sysfs "$rootfs_mount/sys"
	mount --bind /run "$rootfs_mount/run"

	write_fast_rootfs_policy_files "$rootfs_mount"
	install -d -m 0755 "$rootfs_mount/usr/local/lib/yeet-vm"
	install -d -m 0755 "$rootfs_mount/etc/systemd/system/multi-user.target.wants"
	install -m 0755 "$guest_init_path" "$rootfs_mount/usr/local/lib/yeet-vm/yeet-init"
	install -m 0755 "$guest_agent_path" "$rootfs_mount/usr/local/lib/yeet-vm/yeet-agent"
	cat >"$rootfs_mount/etc/systemd/system/yeet-agent.service" <<'UNIT'
[Unit]
Description=yeet VM guest agent
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/lib/yeet-vm/yeet-agent
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT
	ln -sf ../yeet-agent.service "$rootfs_mount/etc/systemd/system/multi-user.target.wants/yeet-agent.service"
	install_fast_rootfs_terminfo "$rootfs_mount"
	cat >"$rootfs_mount/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
	chmod +x "$rootfs_mount/usr/sbin/policy-rc.d"

	chroot "$rootfs_mount" /bin/sh <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
packages="$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | awk '/^(linux-image-|linux-modules-|linux-modules-extra-|linux-headers-|linux-generic|linux-virtual|grub-|shim-signed$|initramfs-tools|snapd$|snap-confine$|squashfs-tools$|cloud-init$|pollinate$|apport$|apport-symptoms$|fwupd$|fwupd-signed$|update-notifier-common$|update-manager-core$|xfsprogs$|modemmanager$|udisks2$|multipath-tools$|lvm2$|rsyslog$|ufw$|unattended-upgrades$|open-vm-tools$|open-vm-tools-desktop$|vgauth$|netplan.io$|networkd-dispatcher$|sysstat$|chrony$|plymouth$|plymouth-|keyboard-configuration$|console-setup$)/ { print }')"
if [ -n "$packages" ]; then
	apt-get purge -y $packages
fi
apt-get update
apt-get install -y --no-install-recommends iptables nftables rsync yeet-vm-kernel
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/snapd/* /var/lib/snapd/cache/*
mkdir -p /etc/systemd/system
ln -sf /dev/null /etc/systemd/system/snapd.service
ln -sf /dev/null /etc/systemd/system/snapd.socket
ln -sf /dev/null /etc/systemd/system/snapd.seeded.service
rm -rf /etc/netplan
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/timers.target.wants /etc/systemd/network
ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
ln -sf /usr/lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service
if [ -e /usr/lib/systemd/system/systemd-timesyncd.service ]; then
	ln -sf /usr/lib/systemd/system/systemd-timesyncd.service /etc/systemd/system/multi-user.target.wants/systemd-timesyncd.service
fi
ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
mkdir -p /etc/default
printf 'EXTRA_OPTS=""\n' >/etc/default/cron
for unit in \
	apt-daily.timer \
	apt-daily-upgrade.timer \
	e2scrub_all.timer \
	e2scrub_reap.service \
	fstrim.timer \
	fwupd.service \
	fwupd-refresh.service \
	fwupd-refresh.timer \
	man-db.timer \
	motd-news.timer \
	proc-sys-fs-binfmt_misc.automount \
	proc-sys-fs-binfmt_misc.mount \
	pollinate.service \
	cloud-init.service \
	cloud-config.service \
	cloud-final.service \
	update-notifier-download.service \
	update-notifier-download.timer \
	update-notifier-motd.service \
	update-notifier-motd.timer \
	xfs_scrub_all.service \
	xfs_scrub_all.timer \
	NetworkManager.service \
	NetworkManager-wait-online.service \
	systemd-modules-load.service \
	systemd-networkd-wait-online.service \
	modprobe@.service \
	modprobe@configfs.service \
	modprobe@drm.service \
	modprobe@efi_pstore.service \
	modprobe@fuse.service \
	netplan-configure.service \
	networkd-dispatcher.service \
	sysstat.service \
	sysstat-collect.timer \
	sysstat-summary.timer \
	chrony.service \
	ldconfig.service \
	keyboard-setup.service \
	console-setup.service \
	plymouth-start.service \
	plymouth-read-write.service \
	plymouth-quit.service \
	plymouth-quit-wait.service \
	plymouth-halt.service \
	plymouth-kexec.service \
	plymouth-poweroff.service \
	plymouth-reboot.service \
	plymouth-switch-root.service \
	plymouth-switch-root-initramfs.service
do
	ln -sf /dev/null "/etc/systemd/system/$unit"
done
ldconfig
EOF
	validate_fast_rootfs_ubuntu_compatibility "$rootfs_mount"
	rm -f "$rootfs_mount/usr/sbin/policy-rc.d"
	cleanup_rootfs_mount
	rootfs_mount=""
}

install -m 0644 "$rootfs_source" "$out_dir/rootfs.ext4"
customize_fast_rootfs "$out_dir/rootfs.ext4"
normalize_fast_rootfs_ext4_features "$out_dir/rootfs.ext4"

echo "Compressing rootfs..."
rootfs_size="$(stat -c %s "$out_dir/rootfs.ext4")"
customized_rootfs_sha="$(sha256sum "$out_dir/rootfs.ext4" | awk '{ print $1 }')"
zstd -T0 "-$zstd_level" -f --no-progress -o "$out_dir/rootfs.ext4.zst" "$out_dir/rootfs.ext4"

build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
guest_init_sha="$(sha256sum "$guest_init_path" | awk '{ print $1 }')"
guest_agent_sha="$(sha256sum "$guest_agent_path" | awk '{ print $1 }')"

"$repo_root/scripts/render-guest-manifest.sh" \
	--guest-base-id "$guest_base_id" \
	--os ubuntu \
	--os-version 26.04 \
	--architecture amd64 \
	--rootfs "$out_dir/rootfs.ext4.zst" \
	--uncompressed-bytes "$rootfs_size" \
	--default-kernel-channel stable \
	--source-commit "$images_source_rev" \
	--workflow-run-url "$workflow_run_url" \
	--out "$out_dir/guest-manifest.json"

jq -n \
	--arg guest_base_id "$guest_base_id" \
	--arg build_time "$build_time" \
	--arg images_source_rev "$images_source_rev" \
	--arg workflow_run_url "$workflow_run_url" \
	--arg yeet_source_rev "$yeet_source_rev" \
	--arg ubuntu_cloud_image_url "$ubuntu_base_url/$ubuntu_image" \
	--arg ubuntu_cloud_image_sha256 "$actual_image_sha" \
	--arg ubuntu_cloud_sha256sums_url "$ubuntu_base_url/SHA256SUMS" \
	--arg customized_rootfs_sha256 "$customized_rootfs_sha" \
	--arg guest_init_sha256 "$guest_init_sha" \
	--arg guest_agent_sha256 "$guest_agent_sha" \
	--arg kernel_release "$kernel_release" \
	--arg kernel_manifest_sha256 "$kernel_manifest_sha256" '
	{
		schema_version: 1,
		guest_base_id: $guest_base_id,
		build_time: $build_time,
		source: {
			images_commit: $images_source_rev,
			workflow_run_url: $workflow_run_url,
			yeet_commit: $yeet_source_rev,
			ubuntu_cloud_image_url: $ubuntu_cloud_image_url,
			ubuntu_cloud_image_sha256: $ubuntu_cloud_image_sha256,
			ubuntu_cloud_sha256sums_url: $ubuntu_cloud_sha256sums_url,
			customized_rootfs_sha256: $customized_rootfs_sha256
		},
		guest: {
			init_path: "/usr/local/lib/yeet-vm/yeet-init",
			init_sha256: $guest_init_sha256,
			agent_path: "/usr/local/lib/yeet-vm/yeet-agent",
			agent_sha256: $guest_agent_sha256
		},
		kernel_request: {
			release_id: $kernel_release,
			manifest_sha256: $kernel_manifest_sha256
		}
	}' >"$out_dir/provenance.json"

(
	cd "$out_dir"
	sha256sum rootfs.ext4.zst guest-manifest.json provenance.json >checksums.txt
)

rm -f "$out_dir/rootfs.ext4"

echo "Wrote Ubuntu guest base to $out_dir"
echo "Guest base: $guest_base_id"
echo "Default kernel request: $kernel_release"
