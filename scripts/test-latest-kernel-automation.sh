#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
script_dir="${script_source%/*}"
if [ "$script_dir" = "$script_source" ]; then
	script_dir="."
fi
script_dir="$(cd "$script_dir" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
testdata_dir="$repo_root/scripts/testdata"

assert_builder_manifest_field() {
	builder="$1"
	field="$2"

	if ! grep -Fq "\"$field\"" "$builder"; then
		echo "$builder does not include manifest field \"$field\"" >&2
		exit 1
	fi
}

assert_builder_omits_unconditional_optional_manifest_field() {
	builder="$1"
	field="$2"

	if grep -Fq "\"$field\": \"\$$field\"" "$builder"; then
		echo "$builder emits optional manifest field \"$field\" unconditionally" >&2
		exit 1
	fi
}

for builder in "$repo_root/scripts/build-ubuntu-26.04.sh" "$repo_root/scripts/build-nixos-26.05.sh"; do
	for field in upstream_kernel_version kernel_source_url kernel_source_sha256 image_revision; do
		assert_builder_manifest_field "$builder" "$field"
	done
	for field in upstream_kernel_version kernel_source_url kernel_source_sha256; do
		assert_builder_omits_unconditional_optional_manifest_field "$builder" "$field"
	done
done
assert_builder_manifest_field "$repo_root/scripts/build-ubuntu-26.04.sh" "yeet_rev"
grep -Fq 'YEET_SOURCE_REV' "$repo_root/scripts/build-ubuntu-26.04.sh"
grep -Fq "YEET_SOURCE_REV=\$(git rev-parse HEAD)" "$repo_root/.github/workflows/build-ubuntu-26.04.yml"
grep -Fq ".provenance.yeet_rev == env.YEET_SOURCE_REV" "$repo_root/.github/workflows/build-ubuntu-26.04.yml"

expected_manifest_version_pattern='(v[0-9]+|kernel-[0-9]+[.][0-9]+([.][0-9]+)?-v[0-9]+)'
manifest_version_pattern="$(sed -n "s/^manifest_version_pattern='\(.*\)'$/\1/p" "$repo_root/scripts/verify-catalog.sh")"
if [ "$manifest_version_pattern" != "$expected_manifest_version_pattern" ]; then
	echo "verify-catalog.sh does not accept hybrid kernel manifest versions" >&2
	exit 1
fi

version_prefix="ubuntu-26.04-amd64-"
version_prefix_regex="${version_prefix//./\\.}"
version_re="^${version_prefix_regex}${manifest_version_pattern}$"
jq -n -e --arg version "ubuntu-26.04-amd64-v16" --arg version_re "$version_re" '
  $version | test($version_re)
' >/dev/null
jq -n -e --arg version "ubuntu-26.04-amd64-kernel-7.1.1-v16" --arg version_re "$version_re" '
  $version | test($version_re)
' >/dev/null

tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

extract_builder_function() {
	builder="$1"
	function_name="$2"

	awk -v function_name="$function_name" '
		$0 == function_name "() {" { in_function = 1 }
		in_function { print }
		in_function && $0 == "}" { found = 1; exit }
		END { if (!found) exit 1 }
	' "$builder"
}

run_builder_function() {
	builder="$1"
	function_name="$2"
	shift 2
	helper_file="$tmp_dir/$(basename "$builder").$function_name.sh"

	if ! extract_builder_function "$builder" "$function_name" >"$helper_file"; then
		echo "$builder does not define $function_name" >&2
		return 1
	fi

	bash -s -- "$helper_file" "$function_name" "$@" <<'RUN_BUILDER_FUNCTION'
set -euo pipefail
helper_file="$1"
function_name="$2"
shift 2
. "$helper_file"
"$function_name" "$@"
RUN_BUILDER_FUNCTION
}

assert_revision_helper_returns() {
	builder="$1"
	version="$2"
	expected="$3"

	if ! output="$(run_builder_function "$builder" image_revision_from_version "$version" 2>&1)"; then
		echo "$builder image_revision_from_version failed for $version" >&2
		echo "$output" >&2
		exit 1
	fi
	if [ "$output" != "$expected" ]; then
		echo "$builder image_revision_from_version expected '$expected' for $version but got '$output'" >&2
		exit 1
	fi
}

assert_revision_helper_fails() {
	builder="$1"
	version="$2"

	if output="$(run_builder_function "$builder" image_revision_from_version "$version" 2>&1)"; then
		echo "$builder image_revision_from_version expected failure for $version but got '$output'" >&2
		exit 1
	fi
}

run_builder_revision_validation() {
	builder="$1"
	version="$2"
	revision="$3"
	helper_file="$tmp_dir/$(basename "$builder").validate_image_revision.sh"

	: >"$helper_file"
	if ! extract_builder_function "$builder" image_revision_from_version >>"$helper_file"; then
		echo "$builder does not define image_revision_from_version" >&2
		return 1
	fi
	if ! extract_builder_function "$builder" validate_image_revision >>"$helper_file"; then
		echo "$builder does not define validate_image_revision" >&2
		return 1
	fi

	bash -s -- "$helper_file" "$version" "$revision" <<'RUN_VALIDATE_REVISION'
set -euo pipefail
helper_file="$1"
version="$2"
revision="$3"
. "$helper_file"
validate_image_revision "$version" "$revision"
RUN_VALIDATE_REVISION
}

assert_validate_revision_returns() {
	builder="$1"
	version="$2"
	revision="$3"
	expected="$4"

	if ! output="$(run_builder_revision_validation "$builder" "$version" "$revision" 2>&1)"; then
		echo "$builder validate_image_revision failed for $version revision '$revision'" >&2
		echo "$output" >&2
		exit 1
	fi
	if [ "$output" != "$expected" ]; then
		echo "$builder validate_image_revision expected '$expected' for $version revision '$revision' but got '$output'" >&2
		exit 1
	fi
}

assert_validate_revision_fails() {
	builder="$1"
	version="$2"
	revision="$3"

	if output="$(run_builder_revision_validation "$builder" "$version" "$revision" 2>&1)"; then
		echo "$builder validate_image_revision expected failure for $version revision '$revision' but got '$output'" >&2
		exit 1
	fi
}

assert_optional_manifest_line_returns() {
	builder="$1"
	field="$2"
	value="$3"
	expected="$4"

	if ! output="$(run_builder_function "$builder" manifest_optional_string_line "$field" "$value" 2>&1)"; then
		echo "$builder manifest_optional_string_line failed for $field" >&2
		echo "$output" >&2
		exit 1
	fi
	if [ "$output" != "$expected" ]; then
		echo "$builder manifest_optional_string_line expected '$expected' for $field but got '$output'" >&2
		exit 1
	fi
}

assert_builder_helper_behavior() {
	builder="$1"
	family="$2"

	assert_revision_helper_returns "$builder" "$family-kernel-7.1.1-v16" "16"
	assert_revision_helper_returns "$builder" "$family-kernel-7.1.1" ""
	assert_revision_helper_fails "$builder" "$family-v16x"
	assert_validate_revision_returns "$builder" "$family-kernel-7.1.1-v16" "" "16"
	assert_validate_revision_returns "$builder" "$family-kernel-7.1.1-v16" "16" "16"
	assert_validate_revision_returns "$builder" "$family-kernel-7.1.1" "0" "0"
	assert_validate_revision_fails "$builder" "$family-kernel-7.1.1-v16x" "0"
	assert_validate_revision_fails "$builder" "$family-kernel-7.1.1-v16" "17"
	assert_validate_revision_fails "$builder" "$family-kernel-7.1.1-v16" "abc"

	assert_optional_manifest_line_returns "$builder" "upstream_kernel_version" "" ""
	assert_optional_manifest_line_returns "$builder" "upstream_kernel_version" "7.1.1" '  "upstream_kernel_version": "7.1.1",'
	assert_optional_manifest_line_returns "$builder" "kernel_source_url" "" ""
	assert_optional_manifest_line_returns "$builder" "kernel_source_url" "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz" '  "kernel_source_url": "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz",'
	assert_optional_manifest_line_returns "$builder" "kernel_source_sha256" "" ""
	assert_optional_manifest_line_returns "$builder" "kernel_source_sha256" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" '  "kernel_source_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",'
}

assert_builder_helper_behavior "$repo_root/scripts/build-ubuntu-26.04.sh" "ubuntu-26.04-amd64"
assert_builder_helper_behavior "$repo_root/scripts/build-nixos-26.05.sh" "nixos-26.05-amd64"

cat >"$tmp_dir/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

out=""
url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o)
			out="$2"
			shift 2
			;;
		--retry | --retry-delay | --connect-timeout | --max-time)
			shift 2
			;;
		-*)
			shift
			;;
		*)
			url="$1"
			shift
			;;
	esac
done

case "$url" in
	*ubuntu/26.04* | *ubuntu-26.04-amd64*)
		family="ubuntu-26.04-amd64"
		;;
	*nixos/26.05* | *nixos-26.05-amd64*)
		family="nixos-26.05-amd64"
		;;
	*)
		echo "unexpected manifest URL: $url" >&2
		exit 1
		;;
esac

case "${YEET_TEST_MANIFEST_VERSION_STYLE:-hybrid}" in
	legacy)
		version="${family}-v16"
		;;
	hybrid)
		version="${family}-kernel-7.1.1-v16"
		;;
	*)
		echo "unexpected manifest version style: ${YEET_TEST_MANIFEST_VERSION_STYLE:-hybrid}" >&2
		exit 1
		;;
esac

cat >"$out" <<EOF
{
  "version": "$version",
  "guest_init": "/usr/local/lib/yeet-vm/yeet-init",
  "guest_agent": "/usr/local/lib/yeet-vm/yeet-agent",
  "guest_agent_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "checksums": {}${YEET_TEST_PROVENANCE_JSON:-}
}
EOF
MOCK_CURL
chmod +x "$tmp_dir/curl"

assert_mock_manifest_version_style() {
	style="$1"
	expected_version="$2"
	manifest="$tmp_dir/mock-$style-manifest.json"

	YEET_TEST_MANIFEST_VERSION_STYLE="$style" "$tmp_dir/curl" \
		"https://github.com/yeetrun/yeet-vm-images/releases/download/ubuntu-26.04-amd64-latest/manifest.json" \
		-o "$manifest"
	actual_version="$(jq -r '.version' "$manifest")"
	if [ "$actual_version" != "$expected_version" ]; then
		echo "$style mock manifest expected version $expected_version but got $actual_version" >&2
		exit 1
	fi
}

assert_mock_manifest_version_style "legacy" "ubuntu-26.04-amd64-v16"
assert_mock_manifest_version_style "hybrid" "ubuntu-26.04-amd64-kernel-7.1.1-v16"

run_catalog_provenance_case() {
	name="$1"
	provenance_json="$2"
	expected_result="$3"
	manifest_version_style="${4:-hybrid}"

	if output="$(YEET_TEST_MANIFEST_VERSION_STYLE="$manifest_version_style" YEET_TEST_PROVENANCE_JSON="$provenance_json" PATH="$tmp_dir:$PATH" "$repo_root/scripts/verify-catalog.sh" 2>&1)"; then
		actual_result="pass"
	else
		actual_result="fail"
	fi

	if [ "$actual_result" != "$expected_result" ]; then
		echo "$name provenance case expected $expected_result but got $actual_result" >&2
		if [ -n "$output" ]; then
			echo "$output" >&2
		fi
		exit 1
	fi
}

valid_kernel_sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
run_catalog_provenance_case "legacy versions" "" "pass" "legacy"
run_catalog_provenance_case "legacy version with valid upstream_kernel_version" ", \"upstream_kernel_version\": \"7.1.2\"" "pass" "legacy"
run_catalog_provenance_case "absent fields" "" "pass"
run_catalog_provenance_case "valid fields" ", \"upstream_kernel_version\": \"7.1.1\", \"kernel_source_url\": \"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz\", \"kernel_source_sha256\": \"$valid_kernel_sha\"" "pass"
run_catalog_provenance_case "hybrid version with mismatched upstream_kernel_version" ", \"upstream_kernel_version\": \"7.1.2\"" "fail"
run_catalog_provenance_case "present-null upstream_kernel_version" ", \"upstream_kernel_version\": null" "fail"
run_catalog_provenance_case "malformed upstream_kernel_version" ", \"upstream_kernel_version\": \"7.x\"" "fail"
run_catalog_provenance_case "present-null kernel_source_url" ", \"kernel_source_url\": null" "fail"
run_catalog_provenance_case "malformed kernel_source_url" ", \"kernel_source_url\": \"not-a-url\"" "fail"
run_catalog_provenance_case "mismatched kernel_source_url" ", \"upstream_kernel_version\": \"7.1.1\", \"kernel_source_url\": \"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.2.tar.xz\"" "fail"
run_catalog_provenance_case "malformed kernel_source_sha256" ", \"kernel_source_sha256\": \"not-a-sha256\"" "fail"
run_catalog_provenance_case "present-null kernel_source_sha256" ", \"kernel_source_sha256\": null" "fail"

kernel_info="$(
	YEET_KERNEL_RELEASES_JSON_URL="file://$testdata_dir/kernel-releases-7.1.1.json" \
	YEET_KERNEL_SHA256SUMS_URL="file://$testdata_dir/kernel-sha256sums-7.x.asc" \
		"$repo_root/scripts/resolve-latest-kernel.sh"
)"

jq -e '
  .moniker == "stable" and
  .version == "7.1.1" and
  .source_url == "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz" and
  .source_sha256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" and
  .released == "2026-06-19"
' <<<"$kernel_info" >/dev/null

ubuntu_version="$("$repo_root/scripts/next-image-version.sh" ubuntu-26.04-amd64 7.1.2 "$testdata_dir/image-release-tags.txt")"
jq -e '
  .family == "ubuntu-26.04-amd64" and
  .upstream_kernel_version == "7.1.2" and
  .image_revision == 17 and
  .version == "ubuntu-26.04-amd64-kernel-7.1.2-v17"
' <<<"$ubuntu_version" >/dev/null

nixos_version="$("$repo_root/scripts/next-image-version.sh" nixos-26.05-amd64 7.1.2 "$testdata_dir/image-release-tags.txt")"
jq -e '
  .family == "nixos-26.05-amd64" and
  .upstream_kernel_version == "7.1.2" and
  .image_revision == 16 and
  .version == "nixos-26.05-amd64-kernel-7.1.2-v16"
' <<<"$nixos_version" >/dev/null

kernel_release="$("$repo_root/scripts/resolve-kernel-release.sh" 7.1.1 "$testdata_dir/kernel-release-tags.txt")"
jq -e '
  .upstream_kernel_version == "7.1.1" and
  .kernel_version == "linux-7.1.1-yeet" and
  .current_revision == 2 and
  .current_release == "kernel-linux-7.1.1-yeet-v2" and
  .next_revision == 3 and
  .next_release == "kernel-linux-7.1.1-yeet-v3"
' <<<"$kernel_release" >/dev/null

kernel_release_with_malformed_suffix="$("$repo_root/scripts/resolve-kernel-release.sh" 7.1.2 "$testdata_dir/kernel-release-tags.txt")"
jq -e '
  .upstream_kernel_version == "7.1.2" and
  .kernel_version == "linux-7.1.2-yeet" and
  .current_revision == 1 and
  .current_release == "kernel-linux-7.1.2-yeet-v1" and
  .next_revision == 2 and
  .next_release == "kernel-linux-7.1.2-yeet-v2"
' <<<"$kernel_release_with_malformed_suffix" >/dev/null

new_kernel_release="$("$repo_root/scripts/resolve-kernel-release.sh" 7.2.0 "$testdata_dir/kernel-release-tags.txt")"
jq -e '
  .upstream_kernel_version == "7.2.0" and
  .kernel_version == "linux-7.2.0-yeet" and
  .current_revision == 0 and
  .current_release == "" and
  .next_revision == 1 and
  .next_release == "kernel-linux-7.2.0-yeet-v1"
' <<<"$new_kernel_release" >/dev/null

if "$repo_root/scripts/resolve-kernel-release.sh" "7.x" "$testdata_dir/kernel-release-tags.txt" >/dev/null 2>&1; then
	echo "resolve-kernel-release.sh accepted malformed kernel version" >&2
	exit 1
fi
