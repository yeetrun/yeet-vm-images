#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
	cat >&2 <<EOF
usage: $0 --upstream-version vMAJOR.MINOR.PATCH --runtime-id ID --out DIR
          [--allow-unsigned-tag] [--allow-signer-rotation]
EOF
	exit 2
}
fail() { echo "Firecracker runtime build failed: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
atomic_publish() {
	local source="$1" destination="$2" status
	set +e
	"$atomic_rename" "$source" "$destination"
	status=$?
	set -e
	if [ "$status" -eq 4 ]; then
		echo "Firecracker runtime build incomplete: destination is published, but final verification or durability confirmation is incomplete; do not retry this destination" >&2
		return 4
	fi
	[ "$status" -eq 0 ] || fail "atomic output publication failed"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
downloader="$repo_root/scripts/download-firecracker-release.sh"
atomic_rename="$repo_root/scripts/atomic-rename-noreplace.py"
policy_resolver="$repo_root/scripts/resolve-firecracker-runtime-policy.py"
policy_file="$repo_root/security/firecracker-runtime-policy.json"
schema="$repo_root/schemas/firecracker-runtime-manifest.schema.json"
version=""
runtime_id=""
out=""
allow_unsigned=false
allow_rotation=false
while [ "$#" -gt 0 ]; do
	case "$1" in
		--upstream-version) [ "$#" -ge 2 ] || usage; version="$2"; shift 2 ;;
		--runtime-id) [ "$#" -ge 2 ] || usage; runtime_id="$2"; shift 2 ;;
		--out) [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
		--allow-unsigned-tag) allow_unsigned=true; shift ;;
		--allow-signer-rotation) allow_rotation=true; shift ;;
		--help|-h) usage ;;
		*) usage ;;
	esac
done
[ -n "$version" ] && [ -n "$runtime_id" ] && [ -n "$out" ] || usage
[[ "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || fail "invalid upstream version"
[[ "$runtime_id" =~ ^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$ ]] || fail "invalid runtime ID"
id_version="${runtime_id#firecracker-}"
id_version="${id_version%-yeet-v*}"
[ "$id_version" = "$version" ] || fail "runtime ID does not bind the upstream version"
for command in jq sha256sum file python3 git install; do require "$command"; done
[ -x "$downloader" ] && [ -x "$atomic_rename" ] && [ -x "$policy_resolver" ] || fail "runtime helper is missing"
[ -f "$schema" ] && [ -f "$policy_file" ] || fail "runtime contract or policy is missing"

[ "${GITHUB_ACTIONS:-}" = true ] || fail "production build requires GitHub Actions"
[ "${GITHUB_REPOSITORY:-}" = yeetrun/yeet-vm-images ] || fail "unexpected GitHub Actions repository"
provenance_commit="${GITHUB_SHA:-}"
workflow_run="${GITHUB_RUN_ID:-}"
[[ "$provenance_commit" =~ ^[0-9a-f]{40}$ ]] || fail "GITHUB_SHA must be a full lowercase commit"
[[ "$workflow_run" =~ ^[1-9][0-9]*$ ]] || fail "GITHUB_RUN_ID must be a positive decimal ID"
git -C "$repo_root" cat-file -e "$provenance_commit^{commit}" 2>/dev/null || fail "GITHUB_SHA does not name a local commit"
[ "$(git -C "$repo_root" rev-parse HEAD)" = "$provenance_commit" ] || fail "GITHUB_SHA does not equal the checked-out commit"

policy_json="$("$policy_resolver" "$policy_file" "$version")" || fail "version lacks reviewed runtime policy"
schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ] && command -v check-jsonschema >/dev/null 2>&1; then schema_validator="$(command -v check-jsonschema)"
elif [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || fail "missing required command: check-jsonschema"
[ ! -e "$out" ] && [ ! -L "$out" ] || fail "output already exists: $out"
out_parent="$(dirname "$out")"
[ -d "$out_parent" ] && [ ! -L "$out_parent" ] || fail "output parent must be an existing real directory"

umask 077
tmp_dir="$(mktemp -d)"
stage="$(mktemp -d "$out_parent/.firecracker-runtime-staging.XXXXXX")"
published=false
cleanup() { rm -rf "$tmp_dir"; if [ "$published" = false ]; then rm -rf "$stage"; fi; }
trap cleanup EXIT INT TERM
download_args=(--upstream-version "$version" --dest "$tmp_dir/download")
[ "$allow_unsigned" = false ] || download_args+=(--allow-unsigned-tag)
[ "$allow_rotation" = false ] || download_args+=(--allow-signer-rotation)
"$downloader" "${download_args[@]}"
verification="$tmp_dir/download/verification.json"
[ "$(jq -er '.version' "$verification")" = "$version" ] || fail "download verification version mismatch"
source_firecracker="$tmp_dir/download/firecracker-$version-x86_64"
source_jailer="$tmp_dir/download/jailer-$version-x86_64"
for binary in "$source_firecracker" "$source_jailer"; do
	[ -f "$binary" ] && [ ! -L "$binary" ] || fail "runtime component is not a regular file"
	classification="$(file -b "$binary")"
	[[ "$classification" == *"ELF 64-bit LSB"* && "$classification" == *"x86-64"* && "${classification,,}" == *"executable"* ]] || fail "runtime component is not an x86-64 ELF executable"
done
install -m 0755 "$source_firecracker" "$stage/firecracker"
install -m 0755 "$source_jailer" "$stage/jailer"
probe_to_files() {
	local binary="$1" stdout="$2" stderr="$3"
	if [ -n "${YEET_RUNTIME_TEST_PROBE:-}" ]; then
		[ "${YEET_RUNTIME_TEST_MODE:-}" = 1 ] && [ "$(uname -s)" != Linux ] || fail "test probe override is forbidden on this platform"
		"$YEET_RUNTIME_TEST_PROBE" "$binary" --version >"$stdout" 2>"$stderr"
	else
		"$binary" --version >"$stdout" 2>"$stderr"
	fi
}
firecracker_stdout="$tmp_dir/firecracker.stdout"
firecracker_stderr="$tmp_dir/firecracker.stderr"
jailer_stdout="$tmp_dir/jailer.stdout"
jailer_stderr="$tmp_dir/jailer.stderr"
probe_to_files "$stage/firecracker" "$firecracker_stdout" "$firecracker_stderr" || fail "Firecracker version probe failed"
probe_to_files "$stage/jailer" "$jailer_stdout" "$jailer_stderr" || fail "jailer version probe failed"
[ ! -s "$firecracker_stderr" ] && [ ! -s "$jailer_stderr" ] || fail "version probe wrote to stderr"
firecracker_version="$(sed -n '1p' "$firecracker_stdout")"
jailer_version="$(sed -n '1p' "$jailer_stdout")"
[ "$firecracker_version" = "Firecracker $version" ] || fail "Firecracker version probe mismatch"
[ "$jailer_version" = "Jailer $version" ] || fail "jailer version probe mismatch"
firecracker_remainder="$(sed '1d; /^[[:space:]]*$/d' "$firecracker_stdout")"
jailer_remainder="$(sed '1d; /^[[:space:]]*$/d' "$jailer_stdout")"
if [ -n "$firecracker_remainder" ]; then
	[ "$(printf '%s\n' "$firecracker_remainder" | awk 'END { print NR }')" = 1 ] &&
		grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{1,9} \[anonymous-instance:main\] Firecracker exiting successfully[.] exit_code=0$' <<<"$firecracker_remainder" ||
		fail "Firecracker version probe emitted unexpected output"
fi
[ -z "$jailer_remainder" ] || fail "jailer version probe emitted unexpected output"
firecracker_digest="$(sha256sum "$stage/firecracker" | awk '{print $1}')"
jailer_digest="$(sha256sum "$stage/jailer" | awk '{print $1}')"
jq -n --arg runtime_id "$runtime_id" --argjson upstream "$(cat "$verification")" --argjson policy "$policy_json" \
	--arg firecracker_digest "$firecracker_digest" --arg jailer_digest "$jailer_digest" \
	--arg firecracker_version "$firecracker_version" --arg jailer_version "$jailer_version" \
	--arg provenance_commit "$provenance_commit" --arg workflow_run "$workflow_run" '
  {schema_version:1,runtime_id:$runtime_id,architecture:"amd64",upstream:$upstream,
   components:{firecracker:{path:"firecracker",sha256:$firecracker_digest,version_output:$firecracker_version},
               jailer:{path:"jailer",sha256:$jailer_digest,version_output:$jailer_version}},
   classification:{production_release:$policy.production_release,default_seccomp:$policy.default_seccomp},
   support:{state:$policy.support_state,policy_url:$policy.policy_url},
   provenance:{repository:"yeetrun/yeet-vm-images",commit:$provenance_commit,workflow_run:$workflow_run}}
' >"$stage/runtime-manifest.json"
chmod 0644 "$stage/runtime-manifest.json"
"$schema_validator" --schemafile "$schema" "$stage/runtime-manifest.json" >/dev/null || fail "generated manifest is not schema-valid"
(
	cd "$stage"
	sha256sum firecracker jailer runtime-manifest.json >runtime-checksums.txt
	sha256sum --check --strict runtime-checksums.txt >/dev/null
	chmod 0644 runtime-checksums.txt
)
chmod 0755 "$stage"
atomic_publish "$stage" "$out"
published=true
