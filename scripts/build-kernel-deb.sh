#!/usr/bin/env bash
set -euo pipefail

kernel_dir="${1:-}"
out_dir="${2:-dist/kernel-packages/deb}"
version="${YEET_VM_KERNEL_VERSION:-}"

if [ -z "$kernel_dir" ] || [ -z "$version" ]; then
	echo "usage: YEET_VM_KERNEL_VERSION=linux-X.Y.Z-yeet scripts/build-kernel-deb.sh <kernel-dir> [out-dir]" >&2
	exit 2
fi
if [[ ! "$version" =~ ^linux-[0-9]+[.][0-9]+([.][0-9]+)?-yeet$ ]]; then
	echo "YEET_VM_KERNEL_VERSION must look like linux-X.Y.Z-yeet: $version" >&2
	exit 2
fi

for cmd in dpkg-deb install mktemp sed sha256sum; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "missing required command: $cmd" >&2
		exit 1
	fi
done
for asset in vmlinux kernel.config; do
	if [ ! -r "$kernel_dir/$asset" ]; then
		echo "missing kernel package asset: $kernel_dir/$asset" >&2
		exit 1
	fi
done

work_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

pkg_root="$work_dir/yeet-vm-kernel"
install -d -m 0755 "$pkg_root/DEBIAN"
install -d -m 0755 "$pkg_root/usr/lib/yeet-vm/kernels/$version"
install -d -m 0755 "$pkg_root/usr/lib/yeet-vm-kernel"

deb_version="${version#linux-}"
deb_version="${deb_version%-yeet}"
sed "s/@DEB_VERSION@/$deb_version/" packages/kernel/deb/DEBIAN/control.in >"$pkg_root/DEBIAN/control"
install -m 0755 packages/kernel/deb/usr/lib/yeet-vm-kernel/select-kernel "$pkg_root/usr/lib/yeet-vm-kernel/select-kernel"
install -m 0755 packages/kernel/deb/usr/lib/yeet-vm-kernel/sync-message "$pkg_root/usr/lib/yeet-vm-kernel/sync-message"
install -m 0644 "$kernel_dir/vmlinux" "$pkg_root/usr/lib/yeet-vm/kernels/$version/vmlinux"
install -m 0644 "$kernel_dir/kernel.config" "$pkg_root/usr/lib/yeet-vm/kernels/$version/kernel.config"

cat >"$pkg_root/DEBIAN/postinst" <<POSTINST
#!/usr/bin/env bash
set -euo pipefail
/usr/lib/yeet-vm-kernel/select-kernel "$version"
/usr/lib/yeet-vm-kernel/sync-message "$version"
POSTINST
chmod 0755 "$pkg_root/DEBIAN/postinst"

mkdir -p "$out_dir"
dpkg-deb --build --root-owner-group "$pkg_root" "$out_dir/yeet-vm-kernel_${deb_version}_amd64.deb"
sha256sum "$out_dir/yeet-vm-kernel_${deb_version}_amd64.deb" >"$out_dir/yeet-vm-kernel_${deb_version}_amd64.deb.sha256"
