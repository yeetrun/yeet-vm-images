#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
testdata="$repo_root/scripts/testdata"
generator="$testdata/generate-firecracker-runtime-fixtures.py"
downloader="$repo_root/scripts/download-firecracker-release.sh"
builder="$repo_root/scripts/build-firecracker-runtime.sh"
publisher="$repo_root/scripts/publish-firecracker-runtime-assets.sh"
extractor="$repo_root/scripts/extract-firecracker-archive.py"
atomic_rename="$repo_root/scripts/atomic-rename-noreplace.py"
policy_resolver="$repo_root/scripts/resolve-firecracker-runtime-policy.py"
tmp_dir="$(mktemp -d)"
initial_status="$(git -C "$repo_root" status --porcelain=v1)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "runtime build test failed: $*" >&2; exit 1; }

for command in python3 jq sha256sum git; do command -v "$command" >/dev/null 2>&1 || fail "missing $command"; done
for helper in "$generator" "$downloader" "$builder" "$publisher" "$extractor" "$atomic_rename" "$policy_resolver"; do [ -x "$helper" ] || fail "missing helper: $helper"; done
schema_validator="${CHECK_JSONSCHEMA:-$(mise which check-jsonschema 2>/dev/null || true)}"
[ -x "$schema_validator" ] || fail "missing check-jsonschema"

# The generator never touches tracked fixtures; a private regeneration must byte-match them.
fixture="$tmp_dir/fixture"
python3 "$generator" --output-dir "$fixture" --scenario valid
for name in firecracker-release-v1.16.1.json firecracker-v1.16.1-x86_64.tgz firecracker-v1.16.1-x86_64.tgz.sha256.txt; do
	cmp "$fixture/$name" "$testdata/$name" || fail "committed fixture drift: $name"
done

mkdir "$tmp_dir/bin"
curl_log="$tmp_dir/curl.log" git_log="$tmp_dir/git.log" gpg_log="$tmp_dir/gpg.log" gh_log="$tmp_dir/gh.log"
: >"$curl_log"; : >"$git_log"; : >"$gpg_log"; : >"$gh_log"
real_file="$(command -v file)"

cat >"$tmp_dir/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
disabled=false location=false proto_redir=false max_redirs="" max_filesize="" output="" format="" url="" urls=0 proto="" connect="" max_time=""
headers=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--disable) disabled=true; shift ;;
		--location) location=true; shift ;;
		--fail|--silent|--show-error|--tlsv1.2) shift ;;
		--proto) proto="$2"; shift 2 ;;
		--connect-timeout) connect="$2"; shift 2 ;;
		--max-time) max_time="$2"; shift 2 ;;
		--proto-redir) [ "$2" = '=https' ] || exit 81; proto_redir=true; shift 2 ;;
		--max-redirs) max_redirs="$2"; shift 2 ;;
		--max-filesize) max_filesize="$2"; shift 2 ;;
		--header) headers+=("$2"); shift 2 ;;
		--output) output="$2"; shift 2 ;;
		--write-out) format="$2"; shift 2 ;;
		--location-trusted|-L) echo 'unsafe redirect option' >&2; exit 82 ;;
		-*) echo "unknown curl option $1" >&2; exit 83 ;;
		*) urls=$((urls + 1)); url="$1"; shift ;;
	esac
done
[ "$disabled" = true ] && [ "$urls" = 1 ] && [ "$proto" = '=https' ] && [ "$connect" = 10 ] && [ -n "$output" ] || { echo 'curl config/cardinality violation' >&2; exit 84; }
[ "$format" = $'%{http_code}\n%{url_effective}\n%{num_redirects}' ] || exit 85
printf 'URL=%s LOCATION=%s URLS=%s\n' "$url" "$location" "$urls" >>"$YEET_TEST_CURL_LOG"
case "$url" in
	https://api.github.com/repos/firecracker-microvm/firecracker/releases/tags/v1.16.1)
		[ "$location" = false ] && [ "$max_time" = 60 ] && [ "$max_filesize" = 1048576 ] && [ "${#headers[@]}" = 3 ] || exit 86
		[ "${headers[0]}" = 'Accept: application/vnd.github+json' ] && [ "${headers[1]}" = 'X-GitHub-Api-Version: 2022-11-28' ] && [ "${headers[2]}" = 'User-Agent: yeet-vm-images-firecracker-runtime-ingest/1' ] || exit 86
		cp "$YEET_TEST_FIXTURE/firecracker-release-v1.16.1.json" "$output"
		printf '200\n%s\n0' "$url"
		;;
	https://api.github.com/repos/firecracker-microvm/firecracker/releases/assets/1001|https://api.github.com/repos/firecracker-microvm/firecracker/releases/assets/1002)
		expected_limit=1048576; case "$url" in */1001) expected_limit=134217728 ;; esac
		[ "$location" = true ] && [ "$proto_redir" = true ] && [ "$max_redirs" = 3 ] && [ "$max_time" = 300 ] && [ "$max_filesize" = "$expected_limit" ] && [ "${#headers[@]}" = 3 ] || exit 87
		[ "${headers[0]}" = 'Accept: application/octet-stream' ] && [ "${headers[1]}" = 'X-GitHub-Api-Version: 2022-11-28' ] && [ "${headers[2]}" = 'User-Agent: yeet-vm-images-firecracker-runtime-ingest/1' ] || exit 87
		case "$url" in */1001) source="$YEET_TEST_FIXTURE/firecracker-v1.16.1-x86_64.tgz" ;; *) source="$YEET_TEST_FIXTURE/firecracker-v1.16.1-x86_64.tgz.sha256.txt" ;; esac
		case "${YEET_TEST_CURL_SCENARIO:-redirect}" in
			redirect) cp "$source" "$output"; printf '200\nhttps://release-assets.githubusercontent.com/asset/%s\n1' "${url##*/}" ;;
			direct) cp "$source" "$output"; printf '200\n%s\n0' "$url" ;;
			wrong-host) cp "$source" "$output"; printf '200\nhttps://example.invalid/stolen\n1' ;;
			http-final) cp "$source" "$output"; printf '200\nhttp://release-assets.githubusercontent.com/stolen\n1' ;;
			loop|cap) echo 'curl: (47) Maximum redirects followed' >&2; exit 47 ;;
			oversized-stream) echo 'curl: (63) Maximum file size exceeded' >&2; exit 63 ;;
			*) exit 88 ;;
		esac
		;;
	*) echo "unexpected curl URL $url" >&2; exit 89 ;;
esac
MOCK_CURL
chmod +x "$tmp_dir/bin/curl"

cat >"$tmp_dir/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$YEET_TEST_GIT_LOG"
if [ "${1:-}" = -C ] && [ "$2" = "$YEET_TEST_REPO_ROOT" ]; then
	case "$3" in
		cat-file) [ "$4" = -e ] && [ "$5" = "$GITHUB_SHA^{commit}" ] && [ "${YEET_TEST_PROVENANCE_SCENARIO:-valid}" != nonexistent ] ;;
		rev-parse) [ "$4" = HEAD ] || exit 69; if [ "${YEET_TEST_PROVENANCE_SCENARIO:-valid}" = mismatch ]; then echo 0000000000000000000000000000000000000000; else echo "$GITHUB_SHA"; fi ;;
		*) exit 70 ;;
	esac
	exit
fi
if [ "${1:-}" = -c ] && [ "$2" = protocol.file.allow=never ] && [ "$3" = init ] && [ "$4" = -q ]; then mkdir -p "$5"; exit; fi
if [ "${1:-}" = -C ]; then shift 2; fi
case "${1:-}" in
	remote)
		[ "$2" = add ] && [ "$3" = origin ] && [ "$4" = https://github.com/firecracker-microvm/firecracker.git ] || exit 71
		;;
	fetch)
		[ "$2" = --no-tags ] && [ "$3" = --depth=1 ] && [ "$4" = --force ] && [ "$5" = origin ] && [ "$6" = +refs/tags/v1.16.1:refs/tags/v1.16.1 ] || exit 72
		;;
	cat-file)
		case "$2" in
			-t) [ "$3" = refs/tags/v1.16.1 ] || exit 73; case "${YEET_TEST_GIT_SCENARIO:-lightweight}" in lightweight) echo commit ;; *) echo tag ;; esac ;;
			-p)
				[ "$3" = refs/tags/v1.16.1 ] || exit 73
				case "${YEET_TEST_GIT_SCENARIO:-lightweight}" in
					unsigned-annotated) echo 'unsigned annotated tag' ;;
					pgp|pgp-subkey|pgp-multiple|pgp-bad) printf '%s\n' '-----BEGIN PGP SIGNATURE-----' test '-----END PGP SIGNATURE-----' ;;
					ssh) printf '%s\n' '-----BEGIN SSH SIGNATURE-----' test '-----END SSH SIGNATURE-----' ;;
					x509) printf '%s\n' '-----BEGIN CERTIFICATE-----' test '-----END CERTIFICATE-----' ;;
					malformed) echo '-----BEGIN MYSTERY SIGNATURE-----' ;;
					*) exit 73 ;;
				esac ;;
			*) exit 74 ;;
		esac
		;;
	rev-parse) [ "$2" = 'v1.16.1^{commit}' ] || exit 74; echo 0123456789abcdef0123456789abcdef01234567 ;;
	-c)
		[ "$2" = gpg.format=openpgp ] && [ "$3" = -c ] && [ "$4" = gpg.program=gpg ] || exit 75
		shift 4; [ "$1" = -C ] || exit 76; shift 2; [ "$1" = verify-tag ] && [ "$2" = --raw ] && [ "$3" = v1.16.1 ] || exit 77
		[ "${YEET_TEST_GIT_SCENARIO:-}" != pgp-bad ] || exit 1
		fingerprint="${YEET_TEST_FINGERPRINT:?}"
		signing_fingerprint="$fingerprint"
		if [ "${YEET_TEST_GIT_SCENARIO:-}" = pgp-subkey ]; then signing_fingerprint="${YEET_TEST_SIGNING_FINGERPRINT:?}"; fi
		printf '[GNUPG:] VALIDSIG %s 2026-07-19 0 4 0 1 10 00 %s\n' "$signing_fingerprint" "$fingerprint" >&2
		if [ "${YEET_TEST_GIT_SCENARIO:-}" = pgp-multiple ]; then printf '[GNUPG:] VALIDSIG %s 2026-07-19 0 4 0 1 10 00 %s\n' "${fingerprint/0/A}" "${fingerprint/0/A}" >&2; fi
		;;
	*) echo "unexpected git command $*" >&2; exit 78 ;;
esac
MOCK_GIT
chmod +x "$tmp_dir/bin/git"

cat >"$tmp_dir/bin/gpg" <<'MOCK_GPG'
#!/usr/bin/env bash
set -euo pipefail
printf 'gpg %s\n' "$*" >>"$YEET_TEST_GPG_LOG"
[ "$1" = --batch ] && [ "$2" = --no-options ] && [ "$3" = --homedir ] && [ "$5" = --import ] && [ -f "$6" ] || exit 79
MOCK_GPG
chmod +x "$tmp_dir/bin/gpg"

cat >"$tmp_dir/bin/file" <<'MOCK_FILE'
#!/usr/bin/env bash
set -euo pipefail
if [ "$(uname -s)" = Linux ]; then exec "$YEET_TEST_REAL_FILE" "$@"; fi
case "${YEET_TEST_FILE_SCENARIO:-valid}" in
	valid) echo 'ELF 64-bit LSB executable, x86-64, statically linked' ;;
	wrong-arch) echo 'ELF 64-bit LSB executable, ARM aarch64' ;;
	non-elf) echo 'ASCII text' ;;
esac
MOCK_FILE
chmod +x "$tmp_dir/bin/file"
cat >"$tmp_dir/probe" <<'MOCK_PROBE'
#!/usr/bin/env bash
case "$(basename "$1")" in firecracker) echo 'Firecracker v1.16.1' ;; jailer) echo 'Jailer v1.16.1' ;; *) exit 1 ;; esac
MOCK_PROBE
chmod +x "$tmp_dir/probe"

fingerprint=0123456789ABCDEF0123456789ABCDEF01234567
signing_fingerprint=89ABCDEF0123456789ABCDEF0123456789ABCDEF
head_commit="$(git -C "$repo_root" rev-parse HEAD)"
base_env=(env "PATH=$tmp_dir/bin:$PATH" "CHECK_JSONSCHEMA=$schema_validator" "YEET_RUNTIME_TEST_MODE=1" "YEET_TEST_CURL_LOG=$curl_log" "YEET_TEST_GIT_LOG=$git_log" "YEET_TEST_GPG_LOG=$gpg_log" "YEET_TEST_REPO_ROOT=$repo_root" "YEET_TEST_REAL_FILE=$real_file" "YEET_TEST_FINGERPRINT=$fingerprint" "YEET_TEST_SIGNING_FINGERPRINT=$signing_fingerprint" "GITHUB_ACTIONS=true" "GITHUB_REPOSITORY=yeetrun/yeet-vm-images" "GITHUB_SHA=$head_commit" "GITHUB_RUN_ID=123456789")
if [ "$(uname -s)" != Linux ]; then base_env+=("YEET_RUNTIME_TEST_PROBE=$tmp_dir/probe"); fi

generate_case() { local name="$1" scenario="$2"; local dir="$tmp_dir/cases/$name"; mkdir -p "$dir"; python3 "$generator" --output-dir "$dir" --scenario "$scenario"; echo "$dir"; }
download_case() { local dir="$1" dest="$2"; shift 2; YEET_TEST_FIXTURE="$dir" "${base_env[@]}" "$downloader" --upstream-version v1.16.1 --dest "$dest" "$@"; }
assert_download_failure() {
	local name="$1" scenario="$2" expected="$3"; shift 3
	local dir out message rc
	dir="$(generate_case "$name" "$scenario")"; out="$tmp_dir/failed-$name"
	set +e; message="$(download_case "$dir" "$out" --allow-unsigned-tag "$@" 2>&1)"; rc=$?; set -e
	if [ "$rc" -eq 0 ] || ! grep -Fqi "$expected" <<<"$message"; then fail "$name failed incorrectly: $message"; fi
	[ ! -e "$out" ] || fail "$name published output"
}

# C1/C2: online-only API ingest, bounded redirects, hostile curl config, and no local source interface.
mkdir "$tmp_dir/hostile-home"; printf '%s\n' 'location-trusted = true' >"$tmp_dir/hostile-home/.curlrc"
CURL_HOME="$tmp_dir/hostile-home" YEET_TEST_CURL_SCENARIO=redirect download_case "$fixture" "$tmp_dir/download-redirect" --allow-unsigned-tag
LC_ALL=C.UTF-8 YEET_TEST_CURL_SCENARIO=redirect download_case "$fixture" "$tmp_dir/download-hostile-locale" --allow-unsigned-tag
YEET_TEST_CURL_SCENARIO=direct download_case "$fixture" "$tmp_dir/download-direct" --allow-unsigned-tag
grep -q 'URLS=1' "$curl_log" || fail "curl URL cardinality was not enforced"
set +e; post_rename_download_message="$(YEET_ATOMIC_TEST_FAIL_PARENT_FSYNC=1 YEET_TEST_CURL_SCENARIO=direct download_case "$fixture" "$tmp_dir/download-post-rename" --allow-unsigned-tag 2>&1)"; post_rename_download_rc=$?; set -e
if [ "$post_rename_download_rc" != 4 ] || [ ! -f "$tmp_dir/download-post-rename/verification.json" ] || ! grep -Fqi 'do not retry' <<<"$post_rename_download_message"; then
	fail "downloader did not preserve the published-destination status"
fi
for scenario in wrong-host http-final loop cap; do
	set +e; message="$(YEET_TEST_CURL_SCENARIO="$scenario" download_case "$fixture" "$tmp_dir/redirect-$scenario" --allow-unsigned-tag 2>&1)"; rc=$?; set -e
	[ "$rc" -ne 0 ] || fail "redirect scenario $scenario succeeded"
done
set +e; old_interface="$("${base_env[@]}" "$downloader" --release-json x --archive y --checksum z --dest "$tmp_dir/old" 2>&1)"; old_rc=$?; set -e
if [ "$old_rc" -ne 2 ] || ! grep -Fq 'usage:' <<<"$old_interface"; then fail "caller-controlled local ingest remains"; fi
assert_download_failure malicious-api malicious-api-url 'official metadata'
assert_download_failure malicious-release malicious-release-url 'official non-draft'
assert_download_failure malicious-html malicious-html-url 'official non-draft'
assert_download_failure wrong-api-archive wrong-api-archive-digest 'API digest'
assert_download_failure wrong-api-checksum wrong-api-checksum-digest 'API digest'
assert_download_failure wrong-api-archive-size wrong-api-archive-size 'API size'
assert_download_failure wrong-sidecar wrong-sidecar-digest 'sidecar digest'
assert_download_failure draft draft 'non-draft'
assert_download_failure prerelease prerelease 'non-draft'
assert_download_failure oversized-metadata oversized-metadata 'size exceeds'
set +e; oversized_stream_message="$(YEET_TEST_CURL_SCENARIO=oversized-stream download_case "$fixture" "$tmp_dir/oversized-stream" --allow-unsigned-tag 2>&1)"; oversized_stream_rc=$?; set -e
if [ "$oversized_stream_rc" -eq 0 ] || ! grep -Fqi 'size' <<<"$oversized_stream_message"; then fail "oversized transfer did not fail closed"; fi

# I2 archive parser adversaries: the same bounded parser inspects and copies.
valid_pax="$(generate_case valid-pax valid-pax)"
mkdir "$tmp_dir/valid-pax-output"
"$extractor" "$valid_pax/firecracker-v1.16.1-x86_64.tgz" v1.16.1 "$tmp_dir/valid-pax-output"
for name in SHA256SUMS firecracker-v1.16.1-x86_64 jailer-v1.16.1-x86_64; do
	[ -f "$tmp_dir/valid-pax-output/$name" ] || fail "valid PAX archive omitted $name"
done
[ "$(find "$tmp_dir/valid-pax-output" -type f | wc -l | tr -d ' ')" = 3 ] || fail "ignored PAX archive members were extracted"
for scenario in absolute parent dot duplicate-normalized duplicate-effective symlink hardlink device fifo socket sparse pax pax-size pax-unknown global-pax gnu-longname unexpected-type unexpected-prefix bad-mode invalid-encoding embedded-nul oversized-member oversized-total decompression-bomb; do
	assert_download_failure "$scenario" "$scenario" 'archive inspection failed'
done
compressed_cap="$tmp_dir/compressed-cap.tgz"; truncate -s $((128 * 1024 * 1024 + 1)) "$compressed_cap"; mkdir "$tmp_dir/compressed-cap-out"
if "$extractor" "$compressed_cap" v1.16.1 "$tmp_dir/compressed-cap-out" >/dev/null 2>&1; then fail "compressed archive cap was not enforced"; fi
assert_download_failure wrong-internal wrong-internal-digest 'internal SHA256SUMS'

# I1 private signer state. An isolated empty reviewed key directory fails signed tags closed.
missing_root="$tmp_dir/missing-root"; mkdir -p "$missing_root/scripts" "$missing_root/security/firecracker-trusted-keys"
cp "$downloader" "$extractor" "$atomic_rename" "$missing_root/scripts/"
printf '%s\n' '# empty trust fixture' >"$missing_root/security/firecracker-trusted-signers.txt"
missing_downloader="$missing_root/scripts/download-firecracker-release.sh"
set +e; pgp_missing="$(YEET_TEST_FIXTURE="$fixture" YEET_TEST_GIT_SCENARIO=pgp "${base_env[@]}" "$missing_downloader" --upstream-version v1.16.1 --dest "$tmp_dir/pgp-missing" 2>&1)"; pgp_missing_rc=$?; set -e
if [ "$pgp_missing_rc" -eq 0 ] || ! grep -Fqi 'no reviewed key material' <<<"$pgp_missing"; then fail "signed tag used ambient keyring"; fi
signed_root="$tmp_dir/signed-root"; mkdir -p "$signed_root/scripts" "$signed_root/security/firecracker-trusted-keys"
cp "$downloader" "$extractor" "$atomic_rename" "$signed_root/scripts/"
printf '%s\n' fixture-key >"$signed_root/security/firecracker-trusted-keys/test.asc"
printf '%s\n' "$fingerprint" >"$signed_root/security/firecracker-trusted-signers.txt"
signed_downloader="$signed_root/scripts/download-firecracker-release.sh"
YEET_TEST_FIXTURE="$fixture" YEET_TEST_GIT_SCENARIO=pgp "${base_env[@]}" "$signed_downloader" --upstream-version v1.16.1 --dest "$tmp_dir/signed"
jq -e '.tag_signature.status == "signed"' "$tmp_dir/signed/verification.json" >/dev/null
YEET_TEST_FIXTURE="$fixture" YEET_TEST_GIT_SCENARIO=pgp-subkey "${base_env[@]}" "$signed_downloader" --upstream-version v1.16.1 --dest "$tmp_dir/signed-subkey"
jq -e --arg primary "$fingerprint" '.tag_signature == {status:"signed",fingerprint:$primary}' "$tmp_dir/signed-subkey/verification.json" >/dev/null
printf '%s\n' '# rotation fixture' >"$signed_root/security/firecracker-trusted-signers.txt"
YEET_TEST_FIXTURE="$fixture" YEET_TEST_GIT_SCENARIO=pgp "${base_env[@]}" "$signed_downloader" --upstream-version v1.16.1 --dest "$tmp_dir/rotation" --allow-signer-rotation
jq -e '.tag_signature.status == "signer-rotation-approved"' "$tmp_dir/rotation/verification.json" >/dev/null
for scenario in pgp-multiple pgp-bad ssh x509 malformed; do
	set +e; message="$(YEET_TEST_FIXTURE="$fixture" YEET_TEST_GIT_SCENARIO="$scenario" "${base_env[@]}" "$signed_downloader" --upstream-version v1.16.1 --dest "$tmp_dir/signer-$scenario" --allow-unsigned-tag --allow-signer-rotation 2>&1)"; rc=$?; set -e
	[ "$rc" -ne 0 ] || fail "signer scenario $scenario succeeded"
done
for scenario in lightweight unsigned-annotated; do
	set +e; message="$(YEET_TEST_FIXTURE="$fixture" YEET_TEST_GIT_SCENARIO="$scenario" "${base_env[@]}" "$signed_downloader" --upstream-version v1.16.1 --dest "$tmp_dir/unsigned-$scenario" 2>&1)"; rc=$?; set -e
	if [ "$rc" -eq 0 ] || ! grep -Fqi 'explicit' <<<"$message"; then fail "$scenario lacked explicit approval"; fi
done

# I3/I4 build: reviewed policy, real ELF on Linux, trusted Actions provenance.
valid_out="$tmp_dir/valid-out"
YEET_TEST_FIXTURE="$fixture" "${base_env[@]}" "$builder" --upstream-version v1.16.1 --runtime-id firecracker-v1.16.1-yeet-v1 --out "$valid_out" --allow-unsigned-tag
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-manifest.schema.json" "$valid_out/runtime-manifest.json" >/dev/null
jq -e '.classification == {production_release:true,default_seccomp:true} and .support.state == "supported"' "$valid_out/runtime-manifest.json" >/dev/null
[ "$("$policy_resolver" "$repo_root/security/firecracker-runtime-policy.json" v1.15.0 | jq -r .support_state)" = eol ] || fail "EOL policy did not resolve"
for mutation in production_release default_seccomp binary_origin seccomp_evidence support_state; do
	policy="$tmp_dir/policy-$mutation.json"; cp "$repo_root/security/firecracker-runtime-policy.json" "$policy"
	case "$mutation" in production_release) filter='.versions["v1.16.1"].production_release=false' ;; default_seccomp) filter='.versions["v1.16.1"].default_seccomp=false' ;; binary_origin) filter='.versions["v1.16.1"].binary_origin="local"' ;; seccomp_evidence) filter='.versions["v1.16.1"].seccomp_evidence="disabled"' ;; support_state) filter='.versions["v1.16.1"].support_state="unsupported"' ;; esac
	jq "$filter" "$policy" >"$policy.tmp"; mv "$policy.tmp" "$policy"
	if "$policy_resolver" "$policy" v1.16.1 >/dev/null 2>&1; then fail "unsafe policy mutation accepted: $mutation"; fi
done
for provenance in mismatch nonexistent; do
	set +e; message="$(YEET_TEST_FIXTURE="$fixture" YEET_TEST_PROVENANCE_SCENARIO="$provenance" "${base_env[@]}" "$builder" --upstream-version v1.16.1 --runtime-id firecracker-v1.16.1-yeet-v1 --out "$tmp_dir/provenance-$provenance" --allow-unsigned-tag 2>&1)"; rc=$?; set -e
	[ "$rc" -ne 0 ] || fail "provenance scenario $provenance succeeded"
done
set +e; message="$(YEET_TEST_FIXTURE="$fixture" "${base_env[@]}" GITHUB_RUN_ID=0 "$builder" --upstream-version v1.16.1 --runtime-id firecracker-v1.16.1-yeet-v1 --out "$tmp_dir/bad-run" --allow-unsigned-tag 2>&1)"; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "invalid workflow run was accepted"
set +e; message="$(YEET_TEST_FIXTURE="$fixture" "${base_env[@]}" GITHUB_ACTIONS=false "$builder" --upstream-version v1.16.1 --runtime-id firecracker-v1.16.1-yeet-v1 --out "$tmp_dir/no-actions" --allow-unsigned-tag 2>&1)"; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "build succeeded outside GitHub Actions"

# I5 atomic no-replace, untrusted parents, and controlled source/parent swaps.
source_dir="$tmp_dir/atomic-source"; destination="$tmp_dir/atomic-dest"; mkdir "$source_dir" "$destination"; printf payload >"$source_dir/file"; printf sentinel >"$destination/sentinel"
set +e; "$atomic_rename" "$source_dir" "$destination" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 3 ] && [ "$(cat "$destination/sentinel")" = sentinel ] && [ ! -e "$destination/atomic-source" ] || fail "existing destination was changed or nested"
untrusted_parent="$tmp_dir/untrusted"; mkdir "$untrusted_parent"; chmod 0777 "$untrusted_parent"; mkdir "$untrusted_parent/source"; printf payload >"$untrusted_parent/source/file"
if "$atomic_rename" "$untrusted_parent/source" "$untrusted_parent/dest" >/dev/null 2>&1; then fail "writable parent accepted"; fi
chmod 0700 "$untrusted_parent"
post_rename_source="$tmp_dir/post-rename-source"; mkdir "$post_rename_source"; printf payload >"$post_rename_source/file"
set +e; post_rename_message="$(YEET_RUNTIME_TEST_MODE=1 YEET_ATOMIC_TEST_FAIL_PARENT_FSYNC=1 "$atomic_rename" "$post_rename_source" "$tmp_dir/post-rename-destination" 2>&1)"; post_rename_rc=$?; set -e
if [ "$post_rename_rc" != 4 ] || [ ! -f "$tmp_dir/post-rename-destination/file" ] || [ -e "$post_rename_source" ] || ! grep -Fqi 'do not retry' <<<"$post_rename_message"; then
	fail "post-rename fsync state was ambiguous"
fi
for swap in source parent; do
	base="$tmp_dir/swap-$swap"; mkdir "$base" "$base/source" "$base/destination-parent"; printf payload >"$base/source/file"; pause="$base/pause"
	YEET_RUNTIME_TEST_MODE=1 YEET_ATOMIC_TEST_PAUSE_FILE="$pause" "$atomic_rename" "$base/source" "$base/destination-parent/result" >"$base/output" 2>&1 & pid=$!
	for _ in $(seq 1 1000); do [ -e "$pause.ready" ] && break; sleep 0.01; done
	[ -e "$pause.ready" ] || fail "atomic swap hook did not become ready"
	if [ "$swap" = source ]; then mv "$base/source" "$base/source-old"; mkdir "$base/source"; printf hostile >"$base/source/file"
	else mv "$base/destination-parent" "$base/destination-parent-old"; mkdir "$base/destination-parent"; fi
	: >"$pause.continue"
	set +e; wait "$pid"; rc=$?; set -e
	[ "$rc" -ne 0 ] || fail "$swap swap was accepted"
	[ ! -e "$base/destination-parent/result" ] || fail "$swap swap published at a replaced path"
done

# Strict release-ID GitHub API mock for C3/C4/I6/M3.
cat >"$tmp_dir/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$YEET_TEST_GH_LOG"
[ "$1" = api ] || exit 90; shift
include=false method="" endpoint="" input="" headers=()
while [ "$#" -gt 0 ]; do
	case "$1" in --include) include=true; shift ;; --method) method="$2"; shift 2 ;; --input) input="$2"; shift 2 ;; --header) headers+=("$2"); shift 2 ;; -*) exit 91 ;; *) [ -z "$endpoint" ] || exit 92; endpoint="$1"; shift ;; esac
done
[ "$include" = true ] && [ -n "$method" ] && [ -n "$endpoint" ] || exit 93
scenario="${YEET_TEST_GH_SCENARIO:-success}"; state="$YEET_TEST_GH_STATE"
[ -n "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] || exit 98
respond() { local status="$1" etag="$2" body="$3"; printf 'HTTP/2 %s OK\nETag: %s\n\n%s\n' "$status" "$etag" "$body"; }
asset_json() { local name="$1"; size="$(wc -c <"$YEET_TEST_PUBLISH_OUT/$name" | tr -d ' ')"; digest="sha256:$(sha256sum "$YEET_TEST_PUBLISH_OUT/$name" | awk '{print $1}')"; jq -nc --arg name "$name" --argjson size "$size" --arg digest "$digest" '{name:$name,state:"uploaded",size:$size,digest:$digest}'; }
case "$method $endpoint" in
	"GET repos/yeetrun/yeet-vm-images/immutable-releases") [ "$scenario" != immutable-disabled ] && enabled=true || enabled=false; respond 200 '"immutable"' "{\"enabled\":$enabled}" ;;
	"POST repos/yeetrun/yeet-vm-images/git/refs")
		[ "$scenario" != tag-collision ] || { echo 'HTTP 422 collision' >&2; exit 1; }
		jq -e '.ref=="refs/tags/firecracker-v1.16.1-yeet-v1" and .sha==env.GITHUB_SHA' "$input" >/dev/null || exit 94
		: >"$state.tag"; respond 201 '"ref"' "{\"object\":{\"type\":\"commit\",\"sha\":\"$GITHUB_SHA\"}}" ;;
	"GET repos/yeetrun/yeet-vm-images/git/ref/tags/firecracker-v1.16.1-yeet-v1")
		resolve_count="$(wc -l <"$state.tag-resolves" 2>/dev/null || echo 0)"; printf '%s\n' resolve >>"$state.tag-resolves"
		sha="$GITHUB_SHA"
		if [ "$scenario" = tag-race ] || { [ "$scenario" = late-tag-race ] && [ "$resolve_count" -ge 1 ]; }; then sha=0000000000000000000000000000000000000000; fi
		respond 200 '"ref"' "{\"object\":{\"type\":\"commit\",\"sha\":\"$sha\"}}" ;;
	"POST repos/yeetrun/yeet-vm-images/releases")
		[ -e "$state.tag" ] || exit 95; : >"$state.release"; respond 201 '"release"' '{"id":42,"upload_url":"https://uploads.github.com/repos/yeetrun/yeet-vm-images/releases/42/assets{?name,label}"}' ;;
	POST\ https://uploads.github.com/repos/yeetrun/yeet-vm-images/releases/42/assets\?name=*)
		name="${endpoint##*name=}"; count="$(wc -l <"$state.uploads" 2>/dev/null || echo 0)"
		if [ "$scenario" = second-upload-failure ] && [ "$count" -eq 1 ]; then echo 'HTTP 500 upload failure' >&2; exit 1; fi
		printf '%s\n' "$name" >>"$state.uploads"; body="$(asset_json "$name")"; respond 201 '"asset"' "$body" ;;
	"GET repos/yeetrun/yeet-vm-images/releases/42/assets?per_page=100&page=1")
		list_count="$(wc -l <"$state.asset-lists" 2>/dev/null || echo 0)"; printf '%s\n' list >>"$state.asset-lists"
		assets="$(for name in firecracker jailer runtime-manifest.json runtime-checksums.txt; do asset_json "$name"; done)"
		if [ "$scenario" = remote-extra ] || { [ "$scenario" = fifth-race ] && [ "$list_count" -ge 1 ]; }; then assets="$assets
{\"name\":\"extra\",\"state\":\"uploaded\",\"size\":1,\"digest\":\"sha256:$(printf '0%.0s' {1..64})\"}"; fi
		body="$(jq -sc . <<<"$assets")"; respond 200 '"assets"' "$body" ;;
	"GET repos/yeetrun/yeet-vm-images/releases/42")
		if [ -e "$state.published" ]; then body='{"id":42,"tag_name":"firecracker-v1.16.1-yeet-v1","draft":false,"published_at":"2026-07-19T00:00:00Z","immutable":true}'
		else body='{"id":42,"tag_name":"firecracker-v1.16.1-yeet-v1","draft":true,"published_at":null,"immutable":false}'; fi
		respond 200 '"release-etag"' "$body" ;;
	"PATCH repos/yeetrun/yeet-vm-images/releases/42")
		[ "${#headers[@]}" = 0 ] || exit 96
		: >"$state.published"; respond 200 '"published"' '{"id":42,"draft":false}' ;;
	*) echo "unexpected gh API operation: $method $endpoint" >&2; exit 97 ;;
esac
MOCK_GH
chmod +x "$tmp_dir/bin/gh"

notes="$tmp_dir/notes.md"; printf '%s\n' verified >"$notes"
app_token=task3-test-app-token-sensitive
default_token=task3-test-default-token-sensitive
publisher_base_env=(env "PATH=$tmp_dir/bin:$PATH" "CHECK_JSONSCHEMA=$schema_validator" "YEET_TEST_GH_LOG=$gh_log" "YEET_TEST_PUBLISH_OUT=$valid_out" "GITHUB_ACTIONS=true" "GITHUB_REPOSITORY=yeetrun/yeet-vm-images" "GITHUB_SHA=$head_commit" "GITHUB_TOKEN=$default_token")
publisher_identity_env=("GITHUB_JOB=publish-firecracker-runtime" "GITHUB_WORKFLOW_REF=yeetrun/yeet-vm-images/.github/workflows/sync-latest-stable-firecracker.yml@refs/heads/main" "YEET_RUNTIME_WORKFLOW_REPOSITORY=yeetrun/yeet-vm-images" "YEET_RUNTIME_WORKFLOW_FILE_PATH=.github/workflows/build-firecracker-runtime.yml" "YEET_RUNTIME_WORKFLOW_REF=yeetrun/yeet-vm-images/.github/workflows/build-firecracker-runtime.yml@refs/heads/main" "YEET_RUNTIME_WORKFLOW_SHA=$head_commit")
publisher_env=("${publisher_base_env[@]}" "${publisher_identity_env[@]}" "GH_TOKEN=$app_token")
run_publisher() { local scenario="$1"; local state="$tmp_dir/gh-$scenario"; : >"$state.uploads"; : >"$state.asset-lists"; : >"$state.tag-resolves"; YEET_TEST_GH_SCENARIO="$scenario" YEET_TEST_GH_STATE="$state" "${publisher_env[@]}" "$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 --target "$head_commit" --notes-file "$notes" --out "$valid_out"; }

# C3 bundle contract mutations must fail before any GitHub API operation.
mutate_bundle() { local name="$1" filter="$2"; local dir="$tmp_dir/bundle-$name"; cp -R "$valid_out" "$dir"; jq "$filter" "$dir/runtime-manifest.json" >"$dir/m"; mv "$dir/m" "$dir/runtime-manifest.json"; chmod 0644 "$dir/runtime-manifest.json"; (cd "$dir"; sha256sum firecracker jailer runtime-manifest.json >runtime-checksums.txt; chmod 0644 runtime-checksums.txt); echo "$dir"; }
for case_name in schema runtime-id component provenance; do
	case "$case_name" in schema) filter='.unexpected=true' ;; runtime-id) filter='.runtime_id="firecracker-v1.16.1-yeet-v2"' ;; component) filter='.components.firecracker.sha256=("0"*64)' ;; provenance) filter='.provenance.commit=("0"*40)' ;; esac
	dir="$(mutate_bundle "$case_name" "$filter")"; : >"$gh_log"
	set +e; message="$(YEET_TEST_GH_SCENARIO=success YEET_TEST_GH_STATE="$tmp_dir/never" YEET_TEST_PUBLISH_OUT="$dir" "${publisher_env[@]}" "$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 --target "$head_commit" --notes-file "$notes" --out "$dir" 2>&1)"; rc=$?; set -e
	[ "$rc" -ne 0 ] && [ ! -s "$gh_log" ] || fail "bundle mutation reached GitHub: $case_name"
done
for checksum_case in duplicate missing order; do
	dir="$tmp_dir/checksums-$checksum_case"; cp -R "$valid_out" "$dir"
	case "$checksum_case" in duplicate) sed -n '1p' "$dir/runtime-checksums.txt" >"$dir/extra"; command cat "$dir/extra" >>"$dir/runtime-checksums.txt" ;; missing) sed -n '1,2p' "$dir/runtime-checksums.txt" >"$dir/c"; mv "$dir/c" "$dir/runtime-checksums.txt" ;; order) { sed -n '2p' "$dir/runtime-checksums.txt"; sed -n '1p' "$dir/runtime-checksums.txt"; sed -n '3p' "$dir/runtime-checksums.txt"; } >"$dir/c"; mv "$dir/c" "$dir/runtime-checksums.txt" ;; esac
	chmod 0644 "$dir/runtime-checksums.txt"; : >"$gh_log"
	if YEET_TEST_GH_SCENARIO=success YEET_TEST_GH_STATE="$tmp_dir/never" YEET_TEST_PUBLISH_OUT="$dir" "${publisher_env[@]}" "$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 --target "$head_commit" --notes-file "$notes" --out "$dir" >/dev/null 2>&1; then fail "checksum mutation accepted: $checksum_case"; fi
	[ ! -s "$gh_log" ] || fail "checksum mutation reached GitHub"
done
missing_asset="$tmp_dir/bundle-missing-asset"; cp -R "$valid_out" "$missing_asset"; mv "$missing_asset/jailer" "$tmp_dir/removed-jailer"; : >"$gh_log"
if YEET_TEST_GH_SCENARIO=success YEET_TEST_GH_STATE="$tmp_dir/never" YEET_TEST_PUBLISH_OUT="$missing_asset" "${publisher_env[@]}" "$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 --target "$head_commit" --notes-file "$notes" --out "$missing_asset" >/dev/null 2>&1; then fail "missing asset accepted"; fi
[ ! -s "$gh_log" ] || fail "missing asset reached GitHub"
set +e; message="$(YEET_TEST_GH_SCENARIO=success YEET_TEST_GH_STATE="$tmp_dir/never" "${publisher_env[@]}" GITHUB_SHA=0000000000000000000000000000000000000000 "$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 --target "$head_commit" --notes-file "$notes" --out "$valid_out" 2>&1)"; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "publisher accepted target/GITHUB_SHA mismatch"

# C4/I6/M3 outcome-sensitive GitHub races and preservation.
: >"$gh_log"; set +e; YEET_TEST_GH_SCENARIO=success YEET_TEST_GH_STATE="$tmp_dir/missing-workflow" "${publisher_base_env[@]}" "$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 --target "$head_commit" --notes-file "$notes" --out "$valid_out" >/dev/null 2>&1; missing_workflow_rc=$?; set -e
[ "$missing_workflow_rc" -ne 0 ] && [ ! -s "$gh_log" ] || fail "publisher accepted missing called-workflow identity"
: >"$gh_log"; set +e; missing_token_message="$(YEET_TEST_GH_SCENARIO=success YEET_TEST_GH_STATE="$tmp_dir/missing-token" "${publisher_base_env[@]}" "${publisher_identity_env[@]}" GH_TOKEN= "$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 --target "$head_commit" --notes-file "$notes" --out "$valid_out" 2>&1)"; missing_token_rc=$?; set -e
if [ "$missing_token_rc" -eq 0 ] || [ -s "$gh_log" ] || grep -Fq "$app_token" <<<"$missing_token_message" || grep -Fq "$default_token" <<<"$missing_token_message"; then fail "publisher did not reject a missing explicit App token safely"; fi
invalid_identities=(
	"GITHUB_JOB=unreviewed-publisher"
	"GITHUB_WORKFLOW_REF=yeetrun/yeet-vm-images/.github/workflows/other.yml@refs/heads/main"
	"YEET_RUNTIME_WORKFLOW_REPOSITORY=other/repository"
	"YEET_RUNTIME_WORKFLOW_FILE_PATH=.github/workflows/other.yml"
	"YEET_RUNTIME_WORKFLOW_REF=yeetrun/yeet-vm-images/.github/workflows/build-firecracker-runtime.yml@refs/heads/unreviewed"
	"YEET_RUNTIME_WORKFLOW_SHA=0000000000000000000000000000000000000000"
)
for invalid_identity in "${invalid_identities[@]}"; do
	: >"$gh_log"; set +e
	YEET_TEST_GH_SCENARIO=success YEET_TEST_GH_STATE="$tmp_dir/invalid-workflow" "${publisher_env[@]}" "$invalid_identity" "$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 --target "$head_commit" --notes-file "$notes" --out "$valid_out" >/dev/null 2>&1
	invalid_identity_rc=$?; set -e
	[ "$invalid_identity_rc" -ne 0 ] && [ ! -s "$gh_log" ] || fail "publisher accepted invalid workflow identity: ${invalid_identity%%=*}"
done
: >"$gh_log"; run_publisher success
grep -Fq 'PATCH repos/yeetrun/yeet-vm-images/releases/42' "$gh_log" || fail "publisher did not publish by release ID"
if grep -Eq 'gh release|--clobber|delete' "$gh_log"; then fail "publisher used mutable/destructive CLI"; fi
for scenario in immutable-disabled tag-collision tag-race late-tag-race remote-extra fifth-race second-upload-failure; do
	: >"$gh_log"; set +e; message="$(run_publisher "$scenario" 2>&1)"; rc=$?; set -e
	[ "$rc" -ne 0 ] || fail "publisher scenario $scenario succeeded"
	if grep -Fq 'PATCH repos/yeetrun/yeet-vm-images/releases/42' "$gh_log"; then fail "$scenario attempted publication"; fi
	if [ "$scenario" = second-upload-failure ]; then grep -Fqi 'next packaging revision' <<<"$message" || fail "upload failure omitted remediation"; fi
	if grep -Eqi 'delete|clobber' "$gh_log"; then fail "$scenario used destructive cleanup"; fi
done

[ "$(git -C "$repo_root" status --porcelain=v1)" = "$initial_status" ] || fail "tests changed repository status"
echo "Firecracker runtime build and immutable publishing verified"
