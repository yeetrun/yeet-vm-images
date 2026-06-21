#!/usr/bin/env bash
set -euo pipefail

deb_dir="${1:-dist/kernel-packages/deb}"
repo_dir="${2:-dist/kernel-packages/apt}"
suite="${YEET_APT_SUITE:-stable}"
component="${YEET_APT_COMPONENT:-main}"
arch="${YEET_APT_ARCH:-amd64}"

for cmd in apt-ftparchive gzip install mkdir; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "missing required command: $cmd" >&2
		exit 1
	fi
done
if ! compgen -G "$deb_dir/*.deb" >/dev/null; then
	echo "no .deb files found in $deb_dir" >&2
	exit 1
fi

pool_dir="$repo_dir/pool/$component"
binary_dir="$repo_dir/dists/$suite/$component/binary-$arch"
install -d -m 0755 "$pool_dir" "$binary_dir"
install -m 0644 "$deb_dir"/*.deb "$pool_dir/"

(
	cd "$repo_dir"
	apt-ftparchive packages "pool/$component" >"dists/$suite/$component/binary-$arch/Packages"
	gzip -kf "dists/$suite/$component/binary-$arch/Packages"
	apt-ftparchive \
		-o "APT::FTPArchive::Release::Suite=$suite" \
		-o "APT::FTPArchive::Release::Codename=$suite" \
		-o "APT::FTPArchive::Release::Components=$component" \
		-o "APT::FTPArchive::Release::Architectures=$arch" \
		release "dists/$suite" >"dists/$suite/Release"
)

if [ -n "${YEET_APT_GPG_PRIVATE_KEY:-}" ]; then
	if ! command -v gpg >/dev/null 2>&1; then
		echo "missing required command for signing: gpg" >&2
		exit 1
	fi
	gpg_home="$(mktemp -d)"
	cleanup_gpg() {
		rm -rf "$gpg_home"
	}
	trap cleanup_gpg EXIT
	chmod 0700 "$gpg_home"
	printf '%s\n' "$YEET_APT_GPG_PRIVATE_KEY" | GNUPGHOME="$gpg_home" gpg --batch --import
	key_args=()
	if [ -n "${YEET_APT_GPG_KEY_ID:-}" ]; then
		key_args=(--local-user "$YEET_APT_GPG_KEY_ID")
	fi
	GNUPGHOME="$gpg_home" gpg --batch --yes --armor --detach-sign \
		"${key_args[@]}" \
		-o "$repo_dir/dists/$suite/Release.gpg" \
		"$repo_dir/dists/$suite/Release"
	GNUPGHOME="$gpg_home" gpg --batch --yes --clearsign \
		"${key_args[@]}" \
		-o "$repo_dir/dists/$suite/InRelease" \
		"$repo_dir/dists/$suite/Release"
fi
