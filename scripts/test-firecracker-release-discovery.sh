#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
discovery_resolver="$repo_root/scripts/resolve-latest-firecracker.sh"
revision_resolver="$repo_root/scripts/resolve-firecracker-runtime-release.sh"
testdata_dir="$repo_root/scripts/testdata"
base_fixture="$testdata_dir/firecracker-releases-v1.16.1.json"
tags_fixture="$testdata_dir/firecracker-release-tags.txt"
api_url="https://api.github.com/repos/firecracker-microvm/firecracker/releases?per_page=100"

tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

fail() {
	echo "$*" >&2
	exit 1
}

assert_failure_contains() {
	name="$1"
	expected="$2"
	shift 2

	if output="$("$@" 2>&1)"; then
		fail "$name unexpectedly succeeded"
	fi
	if ! grep -Fqi "$expected" <<<"$output"; then
		fail "$name failed without expected text '$expected': $output"
	fi
}

mutate_fixture() {
	name="$1"
	filter="$2"
	path="$tmp_dir/$name.json"
	jq "$filter" "$base_fixture" >"$path"
	printf '%s\n' "$path"
}

# Fixture mode must not depend on curl or network access.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

: "${YEET_TEST_CURL_LOG:?}"

if [ "${1:-}" != --disable ]; then
	echo "mock curl requires --disable as the first option" >&2
	exit 93
fi
shift

headers=""
body=""
write_out=""
url=""
http_status=200
accept_seen=false
user_agent_seen=false
while [ "$#" -gt 0 ]; do
	case "$1" in
		--disable)
			echo "mock curl received a duplicate or non-leading --disable" >&2
			exit 92
			;;
		--fail-with-body | --silent | --show-error)
			shift
			;;
		--dump-header | -D)
			headers="$2"
			shift 2
			;;
		--output | -o)
			body="$2"
			shift 2
			;;
		--write-out | -w)
			write_out="$2"
			shift 2
			;;
		--header | -H)
			case "$2" in
				"Accept: application/vnd.github+json") accept_seen=true ;;
				"User-Agent: yeet-vm-images-firecracker-release-discovery/1") user_agent_seen=true ;;
				*)
					echo "mock curl received an unknown header: $2" >&2
					exit 91
					;;
			esac
			shift 2
			;;
		--connect-timeout | --max-time | --retry | --retry-delay | --retry-max-time)
			shift 2
			;;
		--location | --location-trusted | -L)
			echo "mock curl received a redirect-enabling option: $1" >&2
			exit 90
			;;
		-*)
			echo "mock curl received an unknown option: $1" >&2
			exit 89
			;;
		*)
			if [ -n "$url" ]; then
				echo "mock curl received multiple URLs" >&2
				exit 2
			fi
			url="$1"
			shift
			;;
	esac
done

printf 'URL=%s Accept: application/vnd.github+json User-Agent: yeet-vm-images-firecracker-release-discovery/1\n' \
	"$url" >>"$YEET_TEST_CURL_LOG"

if [ "${YEET_TEST_CURL_SCENARIO:-forbid}" = "forbid" ]; then
	echo "curl called in fixture mode" >&2
	exit 99
fi
if [ "$accept_seen" != true ] || [ "$user_agent_seen" != true ]; then
	echo "missing explicit GitHub API Accept or User-Agent header" >&2
	exit 98
fi
if [ -z "$headers" ] || [ -z "$body" ] || [ -z "$write_out" ] || [ -z "$url" ]; then
	echo "mock curl missing output/header/status plumbing" >&2
	exit 97
fi
if [ "$write_out" != $'%{http_code}\n%{url_effective}' ]; then
	echo "mock curl received an unexpected status/effective-URL format" >&2
	exit 88
fi

page=1
case "$url" in
	"$YEET_TEST_API_URL") page=1 ;;
	"$YEET_TEST_API_URL&page="*) page="${url##*page=}" ;;
	*)
		echo "unexpected API URL: $url" >&2
		exit 96
		;;
esac

case "$YEET_TEST_CURL_SCENARIO" in
	paginated)
		if [ "$page" -eq 1 ]; then
			cp "$YEET_TEST_PAGE_1" "$body"
			printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; rel="next", <%s&page=2>; rel="last"\r\n\r\n' \
				"$YEET_TEST_API_URL" "$YEET_TEST_API_URL" >"$headers"
		else
			[ "$page" -eq 2 ] || exit 95
			cp "$YEET_TEST_PAGE_2" "$body"
			printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		fi
		;;
	header-boundary-hostile)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 503 Service Unavailable\r\nLink: <%s&page=2>; rel="next"\r\n\r\nHTTP/1.1 200 OK\r\n\r\n' \
			"$YEET_TEST_API_URL" >"$headers"
		;;
	header-boundary-final-next)
		if [ "$page" -eq 1 ]; then
			cp "$YEET_TEST_PAGE_1" "$body"
			printf 'HTTP/1.1 503 Service Unavailable\n\nHTTP/2 200\nLink: <%s&page=2>; rel="next"\n\n' \
				"$YEET_TEST_API_URL" >"$headers"
		else
			[ "$page" -eq 2 ] || exit 95
			cp "$YEET_TEST_PAGE_2" "$body"
			printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		fi
		;;
	header-boundary-malformed-final)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 503 Service Unavailable\r\nLink: <%s&page=2>; rel="next"\r\n\r\nHTTP/1.1 200 OK\r\nLink: <%s&page=2>; rel="next"\r\n' \
			"$YEET_TEST_API_URL" "$YEET_TEST_API_URL" >"$headers"
		;;
	paginated-duplicate)
		if [ "$page" = 1 ]; then
			cp "$YEET_TEST_PAGE_1" "$body"
			printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; rel="next"\r\n\r\n' \
				"$YEET_TEST_API_URL" >"$headers"
		else
			[ "$page" = 2 ] || exit 95
			cp "$YEET_TEST_DUPLICATE_PAGE_2" "$body"
			printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		fi
		;;
	loop)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 200 OK\r\nLink: <%s>; rel="next"\r\n\r\n' \
			"$YEET_TEST_API_URL" >"$headers"
		;;
	unexpected-next-host)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 200 OK\r\nLink: <https://example.invalid/releases?page=2>; rel="next"\r\n\r\n' >"$headers"
		;;
	non-next-relation)
		if [ "$page" -eq 1 ]; then
			cp "$YEET_TEST_PAGE_1" "$body"
			printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; rel=nextish\r\n\r\n' \
				"$YEET_TEST_API_URL" >"$headers"
		else
			cp "$YEET_TEST_PAGE_2" "$body"
			printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		fi
		;;
	hostile-anchor-relation)
		if [ "$page" = 1 ]; then
			cp "$YEET_TEST_PAGE_1" "$body"
			printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; anchor="; rel=next; foo"\r\n\r\n' \
				"$YEET_TEST_API_URL" >"$headers"
		else
			cp "$YEET_TEST_PAGE_2" "$body"
			printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		fi
		;;
	quoted-multi-relation)
		if [ "$page" = 1 ]; then
			cp "$YEET_TEST_PAGE_1" "$body"
			printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; title="page, two; stable"; rel="prev next"\r\n\r\n' \
				"$YEET_TEST_API_URL" >"$headers"
		else
			cp "$YEET_TEST_PAGE_2" "$body"
			printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		fi
		;;
	unquoted-multi-relation)
		if [ "$page" = 1 ]; then
			cp "$YEET_TEST_PAGE_1" "$body"
			printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; rel=prev next; title=stable\r\n\r\n' \
				"$YEET_TEST_API_URL" >"$headers"
		else
			cp "$YEET_TEST_PAGE_2" "$body"
			printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		fi
		;;
	duplicate-next-relation)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; rel=next; rel=last\r\n\r\n' \
			"$YEET_TEST_API_URL" >"$headers"
		;;
	conflicting-next-links)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; rel=next, <%s&page=3>; rel="next"\r\n\r\n' \
			"$YEET_TEST_API_URL" "$YEET_TEST_API_URL" >"$headers"
		;;
	malformed-next-relation)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=2>; rel="next\r\n\r\n' \
			"$YEET_TEST_API_URL" >"$headers"
		;;
	oversized-page)
		if [ "$page" = 1 ]; then
			cp "$YEET_TEST_PAGE_1" "$body"
			printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=18446744073709551618>; rel="next"\r\n\r\n' \
				"$YEET_TEST_API_URL" >"$headers"
		else
			cp "$YEET_TEST_PAGE_2" "$body"
			printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		fi
		;;
	redirected-host)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		url="https://example.invalid/stolen"
		;;
	http-302)
		cp "$YEET_TEST_PAGE_1" "$body"
		printf 'HTTP/1.1 302 Found\r\nLocation: https://example.invalid/stolen\r\n\r\n' >"$headers"
		http_status=302
		;;
	truncated)
		printf '[{"tag_name":"v1.16.1"' >"$body"
		printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
		;;
	page-cap)
		printf '[]\n' >"$body"
		next_page="$((page + 1))"
		printf 'HTTP/1.1 200 OK\r\nLink: <%s&page=%s>; rel="next"\r\n\r\n' \
			"$YEET_TEST_API_URL" "$next_page" >"$headers"
		;;
	http-error)
		echo "the requested URL returned error: 503" >&2
		exit 22
		;;
	*)
		echo "unknown mock curl scenario: $YEET_TEST_CURL_SCENARIO" >&2
		exit 94
		;;
esac

printf '%s\n%s' "$http_status" "$url"
MOCK_CURL
chmod +x "$tmp_dir/bin/curl"
curl_log="$tmp_dir/curl.log"
: >"$curl_log"

cat >"$tmp_dir/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail

: "${YEET_TEST_GIT_LOG:?}"
printf 'git called: %s\n' "$*" >>"$YEET_TEST_GIT_LOG"
echo "git called while a tags fixture was supplied" >&2
exit 99
MOCK_GIT
chmod +x "$tmp_dir/bin/git"
git_log="$tmp_dir/git.log"
: >"$git_log"

result="$(
	YEET_TEST_CURL_LOG="$curl_log" \
		PATH="$tmp_dir/bin:$PATH" \
		"$discovery_resolver" "$base_fixture"
)"
jq -e '
  .upstream_version == "v1.16.1" and
  .architecture == "amd64" and
  .archive_name == "firecracker-v1.16.1-x86_64.tgz" and
  .archive_url == "https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.1/firecracker-v1.16.1-x86_64.tgz" and
  .archive_digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .checksum_name == "firecracker-v1.16.1-x86_64.tgz.sha256.txt" and
  .checksum_url == "https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.1/firecracker-v1.16.1-x86_64.tgz.sha256.txt" and
  .checksum_digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
' <<<"$result" >/dev/null
[ ! -s "$curl_log" ] || fail "fixture discovery unexpectedly called curl"

mkdir -p "$tmp_dir/option-fixtures"
cp "$base_fixture" "$tmp_dir/option-fixtures/--help"
option_fixture_result="$(
	cd "$tmp_dir/option-fixtures"
	YEET_TEST_CURL_LOG="$curl_log" \
		PATH="$tmp_dir/bin:$PATH" \
		"$discovery_resolver" --help
)"
jq -e '.upstream_version == "v1.16.1"' <<<"$option_fixture_result" >/dev/null || \
	fail "option-like releases fixture was not parsed as JSON data"
[ ! -s "$curl_log" ] || fail "option-like releases fixture unexpectedly called curl"

cp "$tags_fixture" "$tmp_dir/option-fixtures/--version"
option_tags_result="$(
	cd "$tmp_dir/option-fixtures"
	YEET_TEST_GIT_LOG="$git_log" \
		PATH="$tmp_dir/bin:$PATH" \
		"$revision_resolver" v1.16.1 --version
)"
jq -e '.next_release == "firecracker-v1.16.1-yeet-v2"' <<<"$option_tags_result" >/dev/null || \
	fail "option-like tags fixture was not parsed as tag data"
[ ! -s "$git_log" ] || fail "option-like tags fixture unexpectedly invoked git"

: >"$curl_log"
assert_failure_contains "explicit empty releases fixture" "not readable" \
	env YEET_TEST_CURL_LOG="$curl_log" PATH="$tmp_dir/bin:$PATH" "$discovery_resolver" ""
[ ! -s "$curl_log" ] || fail "explicit empty releases fixture unexpectedly called curl"

: >"$git_log"
assert_failure_contains "explicit empty tags fixture" "not readable" \
	env YEET_TEST_GIT_LOG="$git_log" PATH="$tmp_dir/bin:$PATH" "$revision_resolver" v1.16.1 ""
[ ! -s "$git_log" ] || fail "explicit empty tags fixture unexpectedly invoked git"

duplicate_release="$(mutate_fixture duplicate-release '. + [(.[] | select(.tag_name == "v1.16.1"))]')"
assert_failure_contains "duplicate stable version" "duplicate" "$discovery_resolver" "$duplicate_release"

missing_archive="$(mutate_fixture missing-archive 'map(if .tag_name == "v1.16.1" then .assets |= map(select(.name != "firecracker-v1.16.1-x86_64.tgz")) else . end)')"
assert_failure_contains "missing x86_64 archive" "exactly one" "$discovery_resolver" "$missing_archive"

missing_checksum="$(mutate_fixture missing-checksum 'map(if .tag_name == "v1.16.1" then .assets |= map(select(.name != "firecracker-v1.16.1-x86_64.tgz.sha256.txt")) else . end)')"
assert_failure_contains "missing checksum sidecar" "exactly one" "$discovery_resolver" "$missing_checksum"

duplicate_archive="$(mutate_fixture duplicate-archive 'map(if .tag_name == "v1.16.1" then .assets += [(.assets[] | select(.name == "firecracker-v1.16.1-x86_64.tgz"))] else . end)')"
assert_failure_contains "ambiguous archive assets" "exactly one" "$discovery_resolver" "$duplicate_archive"

duplicate_checksum="$(mutate_fixture duplicate-checksum 'map(if .tag_name == "v1.16.1" then .assets += [(.assets[] | select(.name == "firecracker-v1.16.1-x86_64.tgz.sha256.txt"))] else . end)')"
assert_failure_contains "ambiguous checksum assets" "exactly one" "$discovery_resolver" "$duplicate_checksum"

unofficial_url="$(mutate_fixture unofficial-url 'map(if .tag_name == "v1.16.1" then .assets |= map(if .name == "firecracker-v1.16.1-x86_64.tgz" then .browser_download_url = "https://example.invalid/firecracker.tgz" else . end) else . end)')"
assert_failure_contains "unofficial archive URL" "unexpected archive URL" "$discovery_resolver" "$unofficial_url"

malformed_digest="$(mutate_fixture malformed-digest 'map(if .tag_name == "v1.16.1" then .assets |= map(if .name == "firecracker-v1.16.1-x86_64.tgz" then .digest = "sha256:not-a-digest" else . end) else . end)')"
assert_failure_contains "malformed GitHub digest" "invalid archive digest" "$discovery_resolver" "$malformed_digest"

without_digests="$(mutate_fixture without-digests 'map(if .tag_name == "v1.16.1" then .assets |= map(del(.digest)) else . end)')"
result_without_digests="$($discovery_resolver "$without_digests")"
jq -e '(has("archive_digest") | not) and (has("checksum_digest") | not)' \
	<<<"$result_without_digests" >/dev/null

printf '{"not":"an array"}\n' >"$tmp_dir/not-array.json"
assert_failure_contains "non-array API payload" "JSON array" "$discovery_resolver" "$tmp_dir/not-array.json"
printf '[{"tag_name":' >"$tmp_dir/truncated.json"
assert_failure_contains "truncated fixture" "invalid" "$discovery_resolver" "$tmp_dir/truncated.json"

jq -s '.[1] + [.[0][0]]' \
	"$testdata_dir/firecracker-releases-page-1.json" \
	"$testdata_dir/firecracker-releases-page-2.json" >"$tmp_dir/firecracker-releases-page-2-duplicate.json"

online_env=(
	env
	"YEET_TEST_CURL_LOG=$curl_log"
	"YEET_TEST_API_URL=$api_url"
	"YEET_TEST_PAGE_1=$testdata_dir/firecracker-releases-page-1.json"
	"YEET_TEST_PAGE_2=$testdata_dir/firecracker-releases-page-2.json"
	"YEET_TEST_DUPLICATE_PAGE_2=$tmp_dir/firecracker-releases-page-2-duplicate.json"
	"PATH=$tmp_dir/bin:$PATH"
)

mkdir -p "$tmp_dir/hostile-curl-home"
printf 'location = true\nlocation-trusted = true\n' >"$tmp_dir/hostile-curl-home/.curlrc"

: >"$curl_log"
hostile_curl_config_result="$(
	CURL_HOME="$tmp_dir/hostile-curl-home" \
		YEET_TEST_CURL_SCENARIO=paginated \
		"${online_env[@]}" "$discovery_resolver"
)"
jq -e '.upstream_version == "v1.16.1"' <<<"$hostile_curl_config_result" >/dev/null
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 2 ] || fail "hostile curl config changed pagination behavior"

: >"$curl_log"
paginated_result="$(YEET_TEST_CURL_SCENARIO=paginated "${online_env[@]}" "$discovery_resolver")"
jq -e '.upstream_version == "v1.16.1"' <<<"$paginated_result" >/dev/null
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 2 ] || fail "paginated discovery did not fetch exactly two pages"
grep -Fq "$api_url" "$curl_log" || fail "discovery did not use the official GitHub API endpoint"
grep -Fq 'Accept: application/vnd.github+json' "$curl_log" || fail "discovery omitted the GitHub API Accept header"
grep -Fq 'User-Agent: yeet-vm-images-firecracker-release-discovery/1' "$curl_log" || fail "discovery omitted its User-Agent"

: >"$curl_log"
header_boundary_hostile_result="$(YEET_TEST_CURL_SCENARIO=header-boundary-hostile "${online_env[@]}" "$discovery_resolver")"
jq -e '.upstream_version == "v1.15.2"' <<<"$header_boundary_hostile_result" >/dev/null || \
	fail "earlier response block Link header was followed"
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 1 ] || fail "earlier response block Link header was followed"

: >"$curl_log"
header_boundary_final_next_result="$(YEET_TEST_CURL_SCENARIO=header-boundary-final-next "${online_env[@]}" "$discovery_resolver")"
jq -e '.upstream_version == "v1.16.1"' <<<"$header_boundary_final_next_result" >/dev/null || \
	fail "final response block Link header was not followed"
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 2 ] || fail "final response block Link header was not followed"

assert_failure_contains "malformed final response header block" "header" \
	env YEET_TEST_CURL_SCENARIO=header-boundary-malformed-final "${online_env[@]:1}" "$discovery_resolver"

assert_failure_contains "stable version duplicated across pagination boundary" "duplicate" \
	env YEET_TEST_CURL_SCENARIO=paginated-duplicate "${online_env[@]:1}" "$discovery_resolver"

: >"$curl_log"
hostile_anchor_result="$(YEET_TEST_CURL_SCENARIO=hostile-anchor-relation "${online_env[@]}" "$discovery_resolver")"
if ! jq -e '.upstream_version == "v1.15.2"' <<<"$hostile_anchor_result" >/dev/null; then
	fail "quoted anchor text was mistaken for a rel=next parameter"
fi
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 1 ] || fail "quoted anchor text was mistaken for a rel=next parameter"

: >"$curl_log"
quoted_multi_result="$(YEET_TEST_CURL_SCENARIO=quoted-multi-relation "${online_env[@]}" "$discovery_resolver")"
jq -e '.upstream_version == "v1.16.1"' <<<"$quoted_multi_result" >/dev/null
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 2 ] || fail "quoted multi-token next relation was not followed"

: >"$curl_log"
unquoted_multi_result="$(YEET_TEST_CURL_SCENARIO=unquoted-multi-relation "${online_env[@]}" "$discovery_resolver")"
jq -e '.upstream_version == "v1.16.1"' <<<"$unquoted_multi_result" >/dev/null
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 2 ] || fail "unquoted multi-token next relation was not followed"

assert_failure_contains "duplicate next relation parameter" "duplicate" \
	env YEET_TEST_CURL_SCENARIO=duplicate-next-relation "${online_env[@]:1}" "$discovery_resolver"
assert_failure_contains "conflicting next links" "ambiguous" \
	env YEET_TEST_CURL_SCENARIO=conflicting-next-links "${online_env[@]:1}" "$discovery_resolver"
assert_failure_contains "malformed next relation" "invalid" \
	env YEET_TEST_CURL_SCENARIO=malformed-next-relation "${online_env[@]:1}" "$discovery_resolver"

: >"$curl_log"
assert_failure_contains "oversized pagination page" "pagination URL" \
	env YEET_TEST_CURL_SCENARIO=oversized-page "${online_env[@]:1}" "$discovery_resolver"
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 1 ] || fail "oversized pagination page was fetched"

: >"$curl_log"
non_next_result="$(YEET_TEST_CURL_SCENARIO=non-next-relation "${online_env[@]}" "$discovery_resolver")"
if ! jq -e '.upstream_version == "v1.15.2"' <<<"$non_next_result" >/dev/null; then
	fail "non-next Link relation was followed"
fi
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 1 ] || fail "non-next Link relation was followed"

assert_failure_contains "pagination loop" "loop" \
	env YEET_TEST_CURL_SCENARIO=loop "${online_env[@]:1}" "$discovery_resolver"
assert_failure_contains "unexpected pagination host" "pagination URL" \
	env YEET_TEST_CURL_SCENARIO=unexpected-next-host "${online_env[@]:1}" "$discovery_resolver"
assert_failure_contains "redirect to unexpected host" "effective URL" \
	env YEET_TEST_CURL_SCENARIO=redirected-host "${online_env[@]:1}" "$discovery_resolver"
assert_failure_contains "exit-zero HTTP redirect status" "HTTP 302" \
	env YEET_TEST_CURL_SCENARIO=http-302 "${online_env[@]:1}" "$discovery_resolver"
assert_failure_contains "truncated API response" "invalid" \
	env YEET_TEST_CURL_SCENARIO=truncated "${online_env[@]:1}" "$discovery_resolver"
assert_failure_contains "pagination safety cap" "20-page" \
	env YEET_TEST_CURL_SCENARIO=page-cap "${online_env[@]:1}" "$discovery_resolver"
assert_failure_contains "GitHub API HTTP error" "503" \
	env YEET_TEST_CURL_SCENARIO=http-error "${online_env[@]:1}" "$discovery_resolver"

release="$($revision_resolver v1.16.1 "$tags_fixture")"
jq -e '
  .upstream_version == "v1.16.1" and
  .current_release == "firecracker-v1.16.1-yeet-v1" and
  .current_revision == 1 and
  .next_release == "firecracker-v1.16.1-yeet-v2" and
  .next_revision == 2
' <<<"$release" >/dev/null
if grep -Fxq "$(jq -r '.next_release' <<<"$release")" "$tags_fixture"; then
	fail "revision resolver chose an existing tag as next release"
fi

printf '%s\n' \
	'firecracker-v1.16.1-yeet-v2' \
	'firecracker-v1.16.1-yeet-v10' \
	'firecracker-v1.16.1-yeet-v3' >"$tmp_dir/unordered-tags.txt"
unordered_release="$($revision_resolver v1.16.1 "$tmp_dir/unordered-tags.txt")"
jq -e '.current_revision == 10 and .next_revision == 11' <<<"$unordered_release" >/dev/null

: >"$tmp_dir/empty-tags.txt"
first_release="$($revision_resolver v1.16.1 "$tmp_dir/empty-tags.txt")"
jq -e '
  .current_revision == 0 and .current_release == "" and
  .next_revision == 1 and .next_release == "firecracker-v1.16.1-yeet-v1"
' <<<"$first_release" >/dev/null

printf '%s\n' \
	'firecracker-v1.16.1-yeet-v1' \
	'firecracker-v1.16.1-yeet-v1' >"$tmp_dir/duplicate-tags.txt"
assert_failure_contains "duplicate packaging revision" "duplicate" \
	"$revision_resolver" v1.16.1 "$tmp_dir/duplicate-tags.txt"

printf '%s\n' 'firecracker-v1.16.1-yeet-v9007199254740991' >"$tmp_dir/overflow-tags.txt"
assert_failure_contains "packaging revision overflow" "overflow" \
	"$revision_resolver" v1.16.1 "$tmp_dir/overflow-tags.txt"

assert_failure_contains "short upstream version" "invalid upstream version" \
	"$revision_resolver" v1.16 "$tags_fixture"
assert_failure_contains "missing upstream version prefix" "invalid upstream version" \
	"$revision_resolver" 1.16.1 "$tags_fixture"
assert_failure_contains "upstream version with trailing data" "invalid upstream version" \
	"$revision_resolver" v1.16.1-extra "$tags_fixture"
assert_failure_contains "missing tags file" "not readable" \
	"$revision_resolver" v1.16.1 "$tmp_dir/absent-tags.txt"

echo "Firecracker release discovery verified"
