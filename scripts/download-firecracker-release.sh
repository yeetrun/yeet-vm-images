#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs intentionally use jq variables.
set -euo pipefail
export LC_ALL=C

usage() {
	cat >&2 <<EOF
usage: $0 --upstream-version vMAJOR.MINOR.PATCH --dest DIR
          [--allow-unsigned-tag] [--allow-signer-rotation]
EOF
	exit 2
}
fail() { echo "Firecracker release download failed: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
atomic_publish() {
	local source="$1" destination="$2" status
	set +e
	"$atomic_rename" "$source" "$destination"
	status=$?
	set -e
	if [ "$status" -eq 4 ]; then
		echo "Firecracker release download incomplete: destination is published, but final verification or durability confirmation is incomplete; do not retry this destination" >&2
		return 4
	fi
	[ "$status" -eq 0 ] || fail "atomic output publication failed"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
extractor="$repo_root/scripts/extract-firecracker-archive.py"
atomic_rename="$repo_root/scripts/atomic-rename-noreplace.py"
trusted_signers="$repo_root/security/firecracker-trusted-signers.txt"
trusted_keys="$repo_root/security/firecracker-trusted-keys"
max_release_json_size=1048576
max_archive_size=134217728
max_checksum_size=1048576
tag=""
dest=""
allow_unsigned=false
allow_rotation=false
while [ "$#" -gt 0 ]; do
	case "$1" in
		--upstream-version) [ "$#" -ge 2 ] || usage; tag="$2"; shift 2 ;;
		--dest) [ "$#" -ge 2 ] || usage; dest="$2"; shift 2 ;;
		--allow-unsigned-tag) allow_unsigned=true; shift ;;
		--allow-signer-rotation) allow_rotation=true; shift ;;
		--help|-h) usage ;;
		*) usage ;;
	esac
done
[ -n "$tag" ] && [ -n "$dest" ] || usage
[[ "$tag" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || fail "invalid stable release tag"
for command in curl jq git gpg sha256sum python3 awk sed grep; do require "$command"; done
[ -x "$extractor" ] && [ -x "$atomic_rename" ] || fail "runtime security helper is missing"
[ -f "$trusted_signers" ] && [ ! -L "$trusted_signers" ] || fail "trusted signer policy is not a regular file"
[ -d "$trusted_keys" ] && [ ! -L "$trusted_keys" ] || fail "trusted key directory is not a real directory"
[ ! -e "$dest" ] && [ ! -L "$dest" ] || fail "destination already exists: $dest"

umask 077
dest_parent="$(dirname "$dest")"
[ -d "$dest_parent" ] && [ ! -L "$dest_parent" ] || fail "destination parent must be an existing real directory"
tmp_dir="$(mktemp -d "$dest_parent/.firecracker-download.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM

api_url="https://api.github.com/repos/firecracker-microvm/firecracker/releases/tags/$tag"
release_json="$tmp_dir/release.json"
api_response="$(curl --disable --fail --silent --show-error \
	--proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
	--max-filesize "$max_release_json_size" \
	--header 'Accept: application/vnd.github+json' \
	--header 'X-GitHub-Api-Version: 2022-11-28' \
	--header 'User-Agent: yeet-vm-images-firecracker-runtime-ingest/1' \
	--output "$release_json" --write-out $'%{http_code}\n%{url_effective}\n%{num_redirects}' \
	"$api_url")" || fail "official GitHub release API query failed"
api_status="$(sed -n '1p' <<<"$api_response")"
api_effective="$(sed -n '2p' <<<"$api_response")"
api_redirects="$(sed -n '3p' <<<"$api_response")"
[ "$api_status" = 200 ] && [ "$api_effective" = "$api_url" ] && [ "$api_redirects" = 0 ] || fail "unexpected GitHub release API response"
jq empty "$release_json" >/dev/null 2>&1 || fail "GitHub release API returned invalid JSON"

archive_name="firecracker-$tag-x86_64.tgz"
checksum_name="$archive_name.sha256.txt"
browser_base="https://github.com/firecracker-microvm/firecracker/releases/download/$tag"
validate_release='
  (.id | type == "number" and . > 0 and floor == .) and
  .url == ("https://api.github.com/repos/firecracker-microvm/firecracker/releases/" + (.id | tostring)) and
  .html_url == ("https://github.com/firecracker-microvm/firecracker/releases/tag/" + $tag) and
  .tag_name == $tag and .draft == false and .prerelease == false and
  (.assets | type == "array") and
  ([.assets[] | select(.name == $archive_name)] | length) == 1 and
  ([.assets[] | select(.name == $checksum_name)] | length) == 1'
if ! jq -e --arg api_url "$api_url" --arg tag "$tag" --arg archive_name "$archive_name" --arg checksum_name "$checksum_name" \
	"$validate_release" "$release_json" >/dev/null; then
	fail "release API record is not the exact official non-draft stable release"
fi

asset_record() {
	local name="$1" browser_url="$2" maximum_size="$3"
	jq -ce --arg name "$name" --arg browser_url "$browser_url" --argjson maximum_size "$maximum_size" '
    .assets[] | select(.name == $name) |
    select(.id | type == "number" and . > 0 and floor == .) |
    select(.url == ("https://api.github.com/repos/firecracker-microvm/firecracker/releases/assets/" + (.id | tostring))) |
    select(.browser_download_url == $browser_url) |
    select(.size | type == "number" and . > 0 and . <= $maximum_size and floor == .) |
    select(.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$release_json" || fail "invalid official metadata or size exceeds policy for $name"
}
archive_asset="$(asset_record "$archive_name" "$browser_base/$archive_name" "$max_archive_size")"
checksum_asset="$(asset_record "$checksum_name" "$browser_base/$checksum_name" "$max_checksum_size")"

download_asset() {
	local record="$1" output="$2" name="$3" maximum_size="$4"
	local url response status effective redirects
	url="$(jq -r '.url' <<<"$record")"
	[[ "$url" =~ ^https://api[.]github[.]com/repos/firecracker-microvm/firecracker/releases/assets/[1-9][0-9]*$ ]] || fail "invalid initial asset API URL"
	response="$(curl --disable --fail --silent --show-error --location \
		--max-redirs 3 --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--connect-timeout 10 --max-time 300 \
		--max-filesize "$maximum_size" \
		--header 'Accept: application/octet-stream' \
		--header 'X-GitHub-Api-Version: 2022-11-28' \
		--header 'User-Agent: yeet-vm-images-firecracker-runtime-ingest/1' \
		--output "$output" --write-out $'%{http_code}\n%{url_effective}\n%{num_redirects}' \
		"$url")" || fail "asset download failed, exceeded size policy, or exceeded redirect policy: $name"
	status="$(sed -n '1p' <<<"$response")"
	effective="$(sed -n '2p' <<<"$response")"
	redirects="$(sed -n '3p' <<<"$response")"
	[ "$status" = 200 ] || fail "unexpected final HTTP status for $name"
	[[ "$redirects" =~ ^[0-3]$ ]] || fail "asset redirect count exceeded policy"
	python3 - "$effective" <<'PY' || fail "asset redirected to a non-allowlisted final URL"
import sys
from urllib.parse import urlsplit
url = urlsplit(sys.argv[1])
allowed = {
    "api.github.com",
    "github.com",
    "release-assets.githubusercontent.com",
    "objects.githubusercontent.com",
    "github-releases.githubusercontent.com",
}
if url.scheme != "https" or url.hostname not in allowed or url.username or url.password or url.port not in (None, 443):
    raise SystemExit(1)
PY
}

archive="$tmp_dir/$archive_name"
checksum="$tmp_dir/$checksum_name"
download_asset "$archive_asset" "$archive" "$archive_name" "$max_archive_size"
download_asset "$checksum_asset" "$checksum" "$checksum_name" "$max_checksum_size"
archive_digest="$(sha256sum "$archive" | awk '{print $1}')"
checksum_digest="$(sha256sum "$checksum" | awk '{print $1}')"
[ "$archive_digest" = "$(jq -r '.digest | sub("^sha256:"; "")' <<<"$archive_asset")" ] || fail "archive does not match official API digest"
[ "$checksum_digest" = "$(jq -r '.digest | sub("^sha256:"; "")' <<<"$checksum_asset")" ] || fail "checksum does not match official API digest"
[ "$(wc -c <"$archive" | tr -d ' ')" = "$(jq -r '.size' <<<"$archive_asset")" ] || fail "archive does not match official API size"
[ "$(wc -c <"$checksum" | tr -d ' ')" = "$(jq -r '.size' <<<"$checksum_asset")" ] || fail "checksum does not match official API size"
sidecar_line="$(sed -n '1p' "$checksum")"
[ "$(awk 'END { print NR }' "$checksum")" = 1 ] || fail "checksum sidecar must contain exactly one record"
if [[ ! "$sidecar_line" =~ ^([0-9a-f]{64})[[:space:]][[:space:]]firecracker-$tag-x86_64[.]tgz$ ]]; then fail "invalid checksum sidecar"; fi
[ "${BASH_REMATCH[1]}" = "$archive_digest" ] || fail "archive does not match sidecar digest"

private_home="$tmp_dir/home"
gnupg_home="$tmp_dir/gnupg"
source_repo="$tmp_dir/source"
mkdir "$private_home" "$gnupg_home"
chmod 0700 "$private_home" "$gnupg_home"
test_env=()
if [ "${YEET_RUNTIME_TEST_MODE:-}" = 1 ]; then
	test_env+=("YEET_TEST_GIT_LOG=${YEET_TEST_GIT_LOG:-}" "YEET_TEST_GPG_LOG=${YEET_TEST_GPG_LOG:-}" \
		"YEET_TEST_GIT_SCENARIO=${YEET_TEST_GIT_SCENARIO:-}" "YEET_TEST_FINGERPRINT=${YEET_TEST_FINGERPRINT:-}" \
		"YEET_TEST_SIGNING_FINGERPRINT=${YEET_TEST_SIGNING_FINGERPRINT:-}" "YEET_TEST_REPO_ROOT=${YEET_TEST_REPO_ROOT:-}")
fi
clean_env=(env -i "PATH=$PATH" "HOME=$private_home" "GNUPGHOME=$gnupg_home" "LC_ALL=C" "GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null" "${test_env[@]}")
key_count=0
shopt -s nullglob
for key in "$trusted_keys"/*.asc; do
	[ -f "$key" ] && [ ! -L "$key" ] || fail "trusted key material is not a regular file"
	"${clean_env[@]}" gpg --batch --no-options --homedir "$gnupg_home" --import "$key" >/dev/null 2>&1 || fail "cannot import reviewed signer key"
	key_count=$((key_count + 1))
done
shopt -u nullglob
"${clean_env[@]}" git -c protocol.file.allow=never init -q "$source_repo"
"${clean_env[@]}" git -C "$source_repo" remote add origin https://github.com/firecracker-microvm/firecracker.git
"${clean_env[@]}" git -C "$source_repo" fetch --no-tags --depth=1 --force origin "+refs/tags/$tag:refs/tags/$tag"
object_type="$("${clean_env[@]}" git -C "$source_repo" cat-file -t "refs/tags/$tag")"
source_commit="$("${clean_env[@]}" git -C "$source_repo" rev-parse "$tag^{commit}")"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || fail "resolved tag commit is invalid"
signature_status=""
fingerprint=""
signing_fingerprint=""
if [ "$object_type" = commit ]; then
	[ "$allow_unsigned" = true ] || fail "lightweight upstream tag requires explicit unsigned approval"
	signature_status="unsigned-approved"
elif [ "$object_type" = tag ]; then
	tag_body="$("${clean_env[@]}" git -C "$source_repo" cat-file -p "refs/tags/$tag")" || fail "cannot inspect annotated tag"
	if grep -Fq -- '-----BEGIN PGP SIGNATURE-----' <<<"$tag_body"; then
		[ "$key_count" -gt 0 ] || fail "signed tag has no reviewed key material"
		verify_output="$tmp_dir/verify-tag.out"
		"${clean_env[@]}" git -c gpg.format=openpgp -c gpg.program=gpg -C "$source_repo" verify-tag --raw "$tag" >"$verify_output" 2>&1 || fail "OpenPGP tag verification failed"
		if ! read -r signing_fingerprint fingerprint < <(awk '
      /\[GNUPG:\] VALIDSIG / {
        n++; signing=$3; primary=$NF
        if (primary !~ /^([0-9A-F]{40}|[0-9A-F]{64})$/) primary=signing
      }
      END { if (n == 1) print signing, primary }
    ' "$verify_output"); then
			fail "tag verification did not produce one VALIDSIG record"
		fi
		[[ "$signing_fingerprint" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ && "$fingerprint" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || fail "tag verification did not produce useful full fingerprints"
		echo "verified OpenPGP signing fingerprint $signing_fingerprint with primary fingerprint $fingerprint" >&2
		trusted_count="$(awk -v wanted="$fingerprint" '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") } NF && $0 !~ /^([0-9A-F]{40}|[0-9A-F]{64})$/ { bad=1 } $0 == wanted { n++ } END { if (bad) exit 2; print n+0 }' "$trusted_signers")" || fail "invalid trusted signer policy"
		if [ "$trusted_count" -eq 1 ]; then signature_status=signed
		elif [ "$trusted_count" -gt 1 ]; then fail "duplicate trusted signer fingerprint"
		elif [ "$allow_rotation" = true ]; then signature_status=signer-rotation-approved
		else fail "verified signer is not reviewed"; fi
	elif grep -Eq -- '-----BEGIN (SSH SIGNATURE|CERTIFICATE|PKCS7|CMS)|-----BEGIN [A-Z0-9 ]*SIGNATURE-----' <<<"$tag_body"; then
		fail "unsupported or malformed signed tag format"
	elif grep -Eq -- '-----BEGIN|SIGNATURE-----' <<<"$tag_body"; then
		fail "malformed signed tag"
	else
		[ "$allow_unsigned" = true ] || fail "unsigned annotated tag requires explicit approval"
		signature_status=unsigned-approved
	fi
else
	fail "tag ref resolves to unexpected object type"
fi

extract_dir="$tmp_dir/extracted"
mkdir "$extract_dir"
"$extractor" "$archive" "$tag" "$extract_dir"
(
	cd "$extract_dir"
	read -r expected_firecracker expected_jailer < <(awk \
		-v firecracker="firecracker-$tag-x86_64" \
		-v jailer="jailer-$tag-x86_64" '
		BEGIN { count = 0 }
		{
			if (NF != 2 || $1 !~ /^[0-9a-f]+$/ || length($1) != 64) exit 1
			name = $2
			if (substr(name, 1, 2) == "./") name = substr(name, 3)
			if (name !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || seen[name]++) exit 1
			count++
			if (name == firecracker) { firecracker_count++; firecracker_digest = $1 }
			if (name == jailer) { jailer_count++; jailer_digest = $1 }
		}
		END {
			if (count < 2 || count > 64 || firecracker_count != 1 || jailer_count != 1) exit 1
			print firecracker_digest, jailer_digest
		}
	' SHA256SUMS) || exit 1
	actual_firecracker="$(sha256sum "firecracker-$tag-x86_64" | awk '{ print $1 }')"
	actual_jailer="$(sha256sum "jailer-$tag-x86_64" | awk '{ print $1 }')"
	if [ "$actual_firecracker" != "$expected_firecracker" ] || [ "$actual_jailer" != "$expected_jailer" ]; then
		exit 1
	fi
) || fail "upstream internal SHA256SUMS verification failed"

stage="$tmp_dir/publish"
mkdir "$stage"
cp "$extract_dir/SHA256SUMS" "$stage/SHA256SUMS"
cp "$extract_dir/firecracker-$tag-x86_64" "$stage/firecracker-$tag-x86_64"
cp "$extract_dir/jailer-$tag-x86_64" "$stage/jailer-$tag-x86_64"
jq -n --arg version "$tag" --arg commit "$source_commit" \
	--arg archive_url "$browser_base/$archive_name" --arg archive_sha256 "$archive_digest" \
	--arg checksum_url "$browser_base/$checksum_name" --arg signature_status "$signature_status" --arg fingerprint "$fingerprint" '
  {repository:"firecracker-microvm/firecracker",version:$version,tag:$version,commit:$commit,
   archive_url:$archive_url,archive_sha256:$archive_sha256,checksum_url:$checksum_url,
   tag_signature:{status:$signature_status,fingerprint:(if $signature_status == "unsigned-approved" then null else $fingerprint end)}}
' >"$stage/verification.json"
atomic_publish "$stage" "$dest"
