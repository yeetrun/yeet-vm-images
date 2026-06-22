#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
script_dir="${script_source%/*}"
if [ "$script_dir" = "$script_source" ]; then
	script_dir="."
fi
script_dir="$(cd "$script_dir" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

kernel_dir="$tmp_dir/kernel"
deb_dir="$tmp_dir/deb"
repo_dir="$tmp_dir/apt"
fake_bin="$tmp_dir/bin"
capture_root="$tmp_dir/deb-root"
mkdir -p "$kernel_dir" "$fake_bin"
printf 'kernel\n' >"$kernel_dir/vmlinux"
printf 'config\n' >"$kernel_dir/kernel.config"

cat >"$fake_bin/dpkg-deb" <<'FAKE_DPKG_DEB'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" != "--build" ] || [ "$2" != "--root-owner-group" ]; then
	echo "unexpected dpkg-deb args: $*" >&2
	exit 1
fi
pkg_root="$3"
out="$4"
rm -rf "$YEET_TEST_CAPTURE_ROOT"
cp -a "$pkg_root" "$YEET_TEST_CAPTURE_ROOT"
printf 'fake deb\n' >"$out"
FAKE_DPKG_DEB
chmod +x "$fake_bin/dpkg-deb"

PATH="$fake_bin:$PATH" \
	YEET_TEST_CAPTURE_ROOT="$capture_root" \
	YEET_VM_KERNEL_VERSION=linux-7.1.1-yeet \
	"$repo_root/scripts/build-kernel-deb.sh" "$kernel_dir" "$deb_dir"

test -s "$deb_dir/yeet-vm-kernel_7.1.1_amd64.deb"
test -s "$deb_dir/yeet-vm-kernel_7.1.1_amd64.deb.sha256"
grep -q '^Package: yeet-vm-kernel$' "$capture_root/DEBIAN/control"
grep -q '^Version: 7.1.1$' "$capture_root/DEBIAN/control"
test -x "$capture_root/DEBIAN/postinst"
test -x "$capture_root/usr/lib/yeet-vm-kernel/select-kernel"
test -x "$capture_root/usr/lib/yeet-vm-kernel/sync-message"
grep -q '/usr/lib/yeet-vm-kernel/sync-message "linux-7.1.1-yeet"' "$capture_root/DEBIAN/postinst"
cmp "$kernel_dir/vmlinux" "$capture_root/usr/lib/yeet-vm/kernels/linux-7.1.1-yeet/vmlinux"
cmp "$kernel_dir/kernel.config" "$capture_root/usr/lib/yeet-vm/kernels/linux-7.1.1-yeet/kernel.config"
message="$(YEET_VM_SERVICE_NAME=tyler-exit-node "$capture_root/usr/lib/yeet-vm-kernel/sync-message" linux-7.1.1-yeet 2>&1)"
printf '%s\n' "$message" | grep -q 'Reboot this VM to boot the selected kernel.'
if printf '%s\n' "$message" | grep -q 'yeet vm kernel sync'; then
	echo "package message should not require manual yeet vm kernel sync" >&2
	exit 1
fi
printf 'tyler-exit-node\n' >"$tmp_dir/hostname"
message="$(env -u YEET_VM_SERVICE_NAME YEET_VM_HOSTNAME_FILE="$tmp_dir/hostname" "$capture_root/usr/lib/yeet-vm-kernel/sync-message" linux-7.1.1-yeet 2>&1)"
printf '%s\n' "$message" | grep -q 'Reboot this VM to boot the selected kernel.'
message="$(YEET_VM_SERVICE_NAME= YEET_VM_HOSTNAME_FILE="$tmp_dir/missing-hostname" "$capture_root/usr/lib/yeet-vm-kernel/sync-message" linux-7.1.1-yeet 2>&1)"
printf '%s\n' "$message" | grep -q 'Reboot this VM to boot the selected kernel.'

cat >"$fake_bin/apt-ftparchive" <<'FAKE_APT_FTPARCHIVE'
#!/usr/bin/env bash
set -euo pipefail

while [ "$#" -gt 0 ] && [ "$1" = "-o" ]; do
	shift 2
done

case "$1" in
	packages)
		echo 'Package: yeet-vm-kernel'
		echo 'Version: 7.1.1'
		;;
	release)
		echo 'Suite: stable'
		echo 'Components: main'
		;;
	*)
		echo "unexpected apt-ftparchive args: $*" >&2
		exit 1
		;;
esac
FAKE_APT_FTPARCHIVE
cat >"$fake_bin/gpg" <<'FAKE_GPG'
#!/usr/bin/env bash
set -euo pipefail

out=
prev=
for arg in "$@"; do
	if [ "$prev" = "-o" ]; then
		out="$arg"
		prev=
		continue
	fi
	prev=
	if [ "$arg" = "-o" ] || [ "$arg" = "--output" ]; then
		prev="-o"
	fi
done
if [ -n "$out" ]; then
	mkdir -p "$(dirname "$out")"
	printf 'fake gpg output\n' >"$out"
fi
exit 0
FAKE_GPG
chmod +x "$fake_bin/apt-ftparchive" "$fake_bin/gpg"

if PATH="$fake_bin:$PATH" "$repo_root/scripts/publish-apt-repo.sh" "$deb_dir" "$repo_dir.unsigned" 2>"$tmp_dir/unsigned.err"; then
	echo "publish-apt-repo.sh should require a signing key by default" >&2
	exit 1
fi
grep -q 'YEET_APT_GPG_PRIVATE_KEY is required' "$tmp_dir/unsigned.err"

PATH="$fake_bin:$PATH" \
	YEET_APT_GPG_PRIVATE_KEY='fake private key' \
	YEET_APT_GPG_KEY_ID='fake@example.invalid' \
	"$repo_root/scripts/publish-apt-repo.sh" "$deb_dir" "$repo_dir"
test -s "$repo_dir/pool/main/yeet-vm-kernel_7.1.1_amd64.deb"
test -s "$repo_dir/dists/stable/main/binary-amd64/Packages"
test -s "$repo_dir/dists/stable/main/binary-amd64/Packages.gz"
test -s "$repo_dir/dists/stable/Release"
test -s "$repo_dir/dists/stable/Release.gpg"
test -s "$repo_dir/dists/stable/InRelease"
test -s "$repo_dir/yeet-vm-kernel-archive-keyring.gpg"

bash -n \
	"$repo_root/packages/kernel/deb/usr/lib/yeet-vm-kernel/select-kernel" \
	"$repo_root/packages/kernel/deb/usr/lib/yeet-vm-kernel/sync-message" \
	"$repo_root/scripts/build-kernel-deb.sh" \
	"$repo_root/scripts/publish-apt-repo.sh"

grep -q 'system.activationScripts.yeet-vm-kernel-sync-message.text' "$repo_root/kernel-packages/flake.nix"
grep -q 'Reboot this VM to boot the selected kernel.' "$repo_root/kernel-packages/flake.nix"
grep -q 'nixosModules.default' "$repo_root/kernel-packages/flake.nix"
grep -q 'metadata.vmlinuxPath or' "$repo_root/kernel-packages/flake.nix"
grep -q 'metadata.kernelConfigPath or' "$repo_root/kernel-packages/flake.nix"
grep -q 'environment.etc."yeet-vm/kernel/selected.json".source' "$repo_root/kernel-packages/flake.nix"
grep -q 'share/yeet-vm/kernel/selected.json' "$repo_root/kernel-packages/flake.nix"
grep -q 'share/yeet-vm/kernel/selected.json' "$repo_root/kernel-packages/yeet-kernel-package.nix"

grep -q 'kernel_release:' "$repo_root/.github/workflows/publish-kernel-packages.yml"
if grep -q 'image_release:' "$repo_root/.github/workflows/publish-kernel-packages.yml"; then
	echo "publish-kernel-packages.yml must not accept image_release" >&2
	exit 1
fi
grep -q 'KERNEL_RELEASE:' "$repo_root/.github/workflows/publish-kernel-packages.yml"
grep -q 'releases/download/${KERNEL_RELEASE}' "$repo_root/.github/workflows/publish-kernel-packages.yml"
grep -q 'YEET_KERNEL_VERSION="$KERNEL_VERSION"' "$repo_root/.github/workflows/publish-kernel-packages.yml"
grep -q 'scripts/download-kernel-release.sh "$KERNEL_RELEASE" "$kernel_dir"' "$repo_root/.github/workflows/publish-kernel-packages.yml"
grep -q 'asset_base="https://github.com/${GITHUB_REPOSITORY}/releases/download/${KERNEL_RELEASE}"' "$repo_root/.github/workflows/publish-kernel-packages.yml"
if grep -q 'IMAGE_RELEASE' "$repo_root/.github/workflows/publish-kernel-packages.yml"; then
	echo "publish-kernel-packages.yml must not use IMAGE_RELEASE" >&2
	exit 1
fi
if grep -q 'asset_base=.*ubuntu-26.04-amd64-kernel' "$repo_root/.github/workflows/publish-kernel-packages.yml"; then
	echo "publish workflow metadata asset base must not use Ubuntu image releases" >&2
	exit 1
fi
