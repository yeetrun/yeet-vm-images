#!/usr/bin/env bash
set -euo pipefail

kernel_dir="${1:-}"
out_dir="${2:-dist/kernel-packages/deb}"
version="${YEET_VM_KERNEL_VERSION:-}"
release_id="${YEET_VM_KERNEL_RELEASE_ID:-}"
manifest_sha256="${YEET_VM_KERNEL_MANIFEST_SHA256:-}"

if [ -z "$kernel_dir" ] || [ -z "$version" ] || [ -z "$release_id" ] || [ -z "$manifest_sha256" ]; then
	echo "usage: YEET_VM_KERNEL_VERSION=linux-X.Y.Z-yeet YEET_VM_KERNEL_RELEASE_ID=kernel-linux-X.Y.Z-yeet-vN YEET_VM_KERNEL_MANIFEST_SHA256=<sha256> scripts/build-kernel-deb.sh <kernel-dir> [out-dir]" >&2
	exit 2
fi
if [[ ! "$release_id" =~ ^kernel-${version}-v[1-9][0-9]*$ ]]; then
	echo "YEET_VM_KERNEL_RELEASE_ID does not match YEET_VM_KERNEL_VERSION: $release_id" >&2
	exit 2
fi
if [[ ! "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]]; then
	echo "YEET_VM_KERNEL_MANIFEST_SHA256 must be a lowercase SHA-256" >&2
	exit 2
fi
if [[ ! "$version" =~ ^linux-[0-9]+[.][0-9]+([.][0-9]+)?-yeet$ ]]; then
	echo "YEET_VM_KERNEL_VERSION must look like linux-X.Y.Z-yeet: $version" >&2
	exit 2
fi

for cmd in dpkg-deb install jq mktemp sed sha256sum; do
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
deb_version="$deb_version-${release_id##*-v}"
sed "s/@DEB_VERSION@/$deb_version/" packages/kernel/deb/DEBIAN/control.in >"$pkg_root/DEBIAN/control"
install -m 0755 packages/kernel/deb/usr/lib/yeet-vm-kernel/select-kernel "$pkg_root/usr/lib/yeet-vm-kernel/select-kernel"
install -m 0755 packages/kernel/deb/usr/lib/yeet-vm-kernel/sync-message "$pkg_root/usr/lib/yeet-vm-kernel/sync-message"
install -m 0644 "$kernel_dir/vmlinux" "$pkg_root/usr/lib/yeet-vm/kernels/$version/vmlinux"
install -m 0644 "$kernel_dir/kernel.config" "$pkg_root/usr/lib/yeet-vm/kernels/$version/kernel.config"
jq -n \
	--arg release_id "$release_id" \
	--arg manifest_sha256 "$manifest_sha256" \
	'{schema_version: 2, release_id: $release_id, manifest_sha256: $manifest_sha256}' \
	>"$pkg_root/usr/lib/yeet-vm/kernels/$version/release.json"
chmod 0644 "$pkg_root/usr/lib/yeet-vm/kernels/$version/release.json"

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
