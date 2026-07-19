#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 [releases-json]" >&2
	exit 2
}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

if [ "$#" -gt 1 ]; then
	usage
fi

require jq

fixture_mode=false
fixture=""
if [ "$#" -eq 1 ]; then
	fixture_mode=true
	fixture="$1"
fi
api_url="https://api.github.com/repos/firecracker-microvm/firecracker/releases?per_page=100"
releases_file=""
tmp_dir=""

cleanup() {
	if [ -n "$tmp_dir" ]; then
		rm -rf "$tmp_dir"
	fi
}
trap cleanup EXIT

validate_api_url() {
	url="$1"
	expected_page="$2"
	actual_page=""

	if [ "$url" = "$api_url" ]; then
		actual_page=1
	elif [[ "$url" =~ ^https://api[.]github[.]com/repos/firecracker-microvm/firecracker/releases[?]per_page=100\&page=([1-9][0-9]*)$ ]]; then
		actual_page="${BASH_REMATCH[1]}"
	elif [[ "$url" =~ ^https://api[.]github[.]com/repos/firecracker-microvm/firecracker/releases[?]page=([1-9][0-9]*)\&per_page=100$ ]]; then
		actual_page="${BASH_REMATCH[1]}"
	else
		echo "invalid GitHub API pagination URL: $url" >&2
		return 1
	fi

	if [ "$actual_page" != "$expected_page" ]; then
		echo "invalid GitHub API pagination URL for page $expected_page: $url" >&2
		return 1
	fi
}

trim_whitespace() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	trimmed_value="$value"
}

split_outside_quotes() {
	local input="$1"
	local delimiter="$2"
	local current=""
	local character=""
	local quoted=false
	local escaped=false
	local index=0

	split_parts=()
	for ((index = 0; index < ${#input}; index++)); do
		character="${input:index:1}"
		if [ "$escaped" = true ]; then
			current+="$character"
			escaped=false
		elif [ "$quoted" = true ] && [ "$character" = \\ ]; then
			current+="$character"
			escaped=true
		elif [ "$character" = '"' ]; then
			current+="$character"
			if [ "$quoted" = true ]; then
				quoted=false
			else
				quoted=true
			fi
		elif [ "$quoted" = false ] && [ "$character" = "$delimiter" ]; then
			split_parts+=("$current")
			current=""
		else
			current+="$character"
		fi
	done

	if [ "$quoted" = true ] || [ "$escaped" = true ]; then
		return 1
	fi
	split_parts+=("$current")
}

decode_link_parameter_value() {
	local raw_value="$1"
	local inner=""
	local decoded=""
	local character=""
	local escaped=false
	local index=0

	if [[ "$raw_value" != '"'* ]]; then
		if [[ "$raw_value" == *'"'* ]]; then
			return 1
		fi
		decoded_link_parameter_value="$raw_value"
		return 0
	fi
	if [ "${#raw_value}" -lt 2 ] || [[ "$raw_value" != *'"' ]]; then
		return 1
	fi

	inner="${raw_value:1:${#raw_value}-2}"
	for ((index = 0; index < ${#inner}; index++)); do
		character="${inner:index:1}"
		if [ "$escaped" = true ]; then
			decoded+="$character"
			escaped=false
		elif [ "$character" = \\ ]; then
			escaped=true
		elif [ "$character" = '"' ]; then
			return 1
		else
			decoded+="$character"
		fi
	done
	if [ "$escaped" = true ]; then
		return 1
	fi
	decoded_link_parameter_value="$decoded"
}

final_response_headers() {
	local headers_file="$1"
	local line=""
	local header_name=""
	local current_block=""
	local final_block=""
	local in_response=false
	local have_final_block=false

	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		if [ -z "$line" ]; then
			if [ "$in_response" = true ]; then
				final_block="$current_block"
				have_final_block=true
				in_response=false
				current_block=""
			fi
			continue
		fi

		if [[ "$line" =~ ^HTTP/[0-9]+([.][0-9]+)?[[:space:]][0-9][0-9][0-9]([[:space:]].*)?$ ]]; then
			if [ "$in_response" = true ]; then
				echo "invalid incomplete GitHub API response header block" >&2
				return 1
			fi
			in_response=true
			current_block=""
			continue
		fi

		if [ "$in_response" != true ]; then
			echo "invalid GitHub API response header dump" >&2
			return 1
		fi
		current_block+="$line"$'\n'
	done <"$headers_file"

	if [ "$in_response" = true ]; then
		echo "invalid incomplete final GitHub API response header block" >&2
		return 1
	fi
	if [ "$have_final_block" != true ]; then
		echo "missing GitHub API response header block" >&2
		return 1
	fi

	while IFS= read -r line || [ -n "$line" ]; do
		if [ -z "$line" ]; then
			continue
		fi
		header_name="${line%%:*}"
		if [ "$header_name" = "$line" ] || [[ ! "$header_name" =~ ^[[:alnum:]-]+$ ]]; then
			echo "invalid final GitHub API response header block" >&2
			return 1
		fi
	done <<<"$final_block"

	printf '%s' "$final_block"
}

next_link_from_headers() {
	local headers_file="$1"
	local final_headers=""
	local link_values=""
	local link_part=""
	local link_target=""
	local link_remainder=""
	local parameter=""
	local parameter_name=""
	local parameter_value=""
	local relation=""
	local relation_token=""
	local relation_seen=false
	local link_has_next=false
	local next_link=""
	local parameter_index=0
	local -a link_parts=()
	local -a parameter_parts=()
	local -a relation_tokens=()

	if ! final_headers="$(final_response_headers "$headers_file")"; then
		return 1
	fi

	link_values="$({
		printf '%s' "$final_headers" |
			sed -n 's/^[Ll][Ii][Nn][Kk]:[[:space:]]*//p'
	} | paste -sd, -)"
	if [ -z "$link_values" ]; then
		printf '\n'
		return 0
	fi

	if ! split_outside_quotes "$link_values" ','; then
		echo "invalid GitHub API Link header quoting" >&2
		return 1
	fi
	link_parts=("${split_parts[@]}")

	for link_part in "${link_parts[@]}"; do
		trim_whitespace "$link_part"
		link_part="$trimmed_value"
		if [[ "$link_part" != \<* ]] || [[ "$link_part" != *\>* ]]; then
			echo "invalid GitHub API Link header value" >&2
			return 1
		fi
		link_remainder="${link_part#<}"
		link_target="${link_remainder%%>*}"
		link_remainder="${link_remainder#*>}"
		if [ -z "$link_target" ]; then
			echo "invalid GitHub API Link target" >&2
			return 1
		fi

		if ! split_outside_quotes "$link_remainder" ';'; then
			echo "invalid GitHub API Link parameter quoting" >&2
			return 1
		fi
		parameter_parts=("${split_parts[@]}")
		trim_whitespace "${parameter_parts[0]}"
		if [ -n "$trimmed_value" ]; then
			echo "invalid GitHub API Link header syntax" >&2
			return 1
		fi

		relation_seen=false
		link_has_next=false
		for ((parameter_index = 1; parameter_index < ${#parameter_parts[@]}; parameter_index++)); do
			trim_whitespace "${parameter_parts[parameter_index]}"
			parameter="$trimmed_value"
			if [[ ! "$parameter" =~ ^([[:alnum:]_-]+)[[:space:]]*=(.*)$ ]]; then
				echo "invalid GitHub API Link parameter" >&2
				return 1
			fi
			parameter_name="$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}")"
			trim_whitespace "${BASH_REMATCH[2]}"
			parameter_value="$trimmed_value"
			if ! decode_link_parameter_value "$parameter_value"; then
				echo "invalid GitHub API Link parameter value" >&2
				return 1
			fi
			if [ "$parameter_name" != rel ]; then
				continue
			fi
			if [ "$relation_seen" = true ]; then
				echo "duplicate GitHub API Link rel parameter" >&2
				return 1
			fi
			relation_seen=true
			relation="$decoded_link_parameter_value"
			read -r -a relation_tokens <<<"$relation"
			if [ "${#relation_tokens[@]}" -eq 0 ]; then
				echo "invalid empty GitHub API Link rel parameter" >&2
				return 1
			fi
			for relation_token in "${relation_tokens[@]}"; do
				if [ "$relation_token" = next ]; then
					link_has_next=true
				fi
			done
		done

		if [ "$link_has_next" = true ]; then
			if [ -n "$next_link" ]; then
				echo "ambiguous GitHub API Link rel=next header" >&2
				return 1
			fi
			next_link="$link_target"
		fi
	done

	printf '%s\n' "$next_link"
}

if [ "$fixture_mode" = true ]; then
	if [ ! -r "$fixture" ]; then
		echo "releases JSON fixture is not readable: $fixture" >&2
		exit 1
	fi
	releases_file="$fixture"
else
	require curl
	tmp_dir="$(mktemp -d)"
	releases_file="$tmp_dir/releases.json"
	seen_urls="$tmp_dir/seen-urls.txt"
	printf '[]\n' >"$releases_file"
	: >"$seen_urls"

	url="$api_url"
	page=1
	while :; do
		validate_api_url "$url" "$page"
		if grep -Fxq -- "$url" "$seen_urls"; then
			echo "GitHub API pagination loop detected at $url" >&2
			exit 1
		fi
		printf '%s\n' "$url" >>"$seen_urls"

		headers="$tmp_dir/headers-$page"
		body="$tmp_dir/body-$page.json"
		if ! curl_result="$(
			curl \
				--disable \
				--fail-with-body \
				--silent \
				--show-error \
				--connect-timeout 15 \
				--max-time 60 \
				--retry 3 \
				--header 'Accept: application/vnd.github+json' \
				--header 'User-Agent: yeet-vm-images-firecracker-release-discovery/1' \
				--dump-header "$headers" \
				--output "$body" \
				--write-out $'%{http_code}\n%{url_effective}' \
				"$url"
		)"; then
			echo "failed to fetch GitHub releases API page $page" >&2
			exit 1
		fi

		if [[ "$curl_result" != *$'\n'* ]]; then
			echo "curl did not report HTTP status and effective URL" >&2
			exit 1
		fi
		http_status="${curl_result%%$'\n'*}"
		effective_url="${curl_result#*$'\n'}"
		if [ "$http_status" != 200 ]; then
			echo "GitHub releases API returned HTTP $http_status for page $page" >&2
			exit 1
		fi
		if [ "$effective_url" != "$url" ]; then
			echo "unexpected GitHub API effective URL: $effective_url" >&2
			exit 1
		fi
		if ! jq -e 'type == "array"' "$body" >/dev/null 2>&1; then
			echo "invalid or truncated GitHub releases JSON array on page $page" >&2
			exit 1
		fi

		combined="$tmp_dir/combined-$page.json"
		jq -s '.[0] + .[1]' "$releases_file" "$body" >"$combined"
		mv "$combined" "$releases_file"

		next_url="$(next_link_from_headers "$headers")"
		if [ -z "$next_url" ]; then
			break
		fi
		if [ "$page" -ge 20 ]; then
			echo "GitHub releases pagination exceeded the 20-page safety cap" >&2
			exit 1
		fi
		next_page="$((page + 1))"
		if grep -Fxq -- "$next_url" "$seen_urls"; then
			echo "GitHub API pagination loop detected at $next_url" >&2
			exit 1
		fi
		validate_api_url "$next_url" "$next_page"
		url="$next_url"
		page="$next_page"
	done
fi

if ! jq -e 'type == "array"' <"$releases_file" >/dev/null 2>&1; then
	echo "invalid GitHub releases JSON array: $releases_file" >&2
	exit 1
fi

jq '
  def numeric_component:
    sub("^0+"; "") | if length == 0 then "0" else . end;
  def version_key:
    capture("^v(?<major>[0-9]+)[.](?<minor>[0-9]+)[.](?<patch>[0-9]+)$") |
    [.major, .minor, .patch] | map(numeric_component);
  def ordering_key:
    version_key | map([length, .]);
  def valid_digest:
    type == "string" and test("^sha256:[0-9a-f]{64}$");

  [
    .[] |
    select(
      (.draft == false) and
      (.prerelease == false) and
      (.tag_name | type == "string" and test("^v[0-9]+[.][0-9]+[.][0-9]+$"))
    )
  ] as $stable |
  if ($stable | length) == 0 then
    error("could not find a stable Firecracker release")
  else . end |
  ($stable | sort_by(.tag_name | ordering_key) | group_by(.tag_name | version_key) |
    map(select(length != 1) | .[0].tag_name)) as $duplicates |
  if ($duplicates | length) != 0 then
    error("duplicate stable Firecracker version: \($duplicates | join(", "))")
  else . end |
  ($stable | sort_by(.tag_name | ordering_key) | last) as $release |
  $release.tag_name as $tag |
  "firecracker-\($tag)-x86_64.tgz" as $archive_name |
  "\($archive_name).sha256.txt" as $checksum_name |
  "https://github.com/firecracker-microvm/firecracker/releases/download/\($tag)/\($archive_name)" as $archive_url |
  "https://github.com/firecracker-microvm/firecracker/releases/download/\($tag)/\($checksum_name)" as $checksum_url |
  if ($release.assets | type) != "array" then
    error("selected Firecracker release assets must be an array")
  else . end |
  [$release.assets[] | select(.name == $archive_name)] as $archives |
  [$release.assets[] | select(.name == $checksum_name)] as $checksums |
  if ($archives | length) != 1 then
    error("selected release must contain exactly one \($archive_name) asset")
  elif ($checksums | length) != 1 then
    error("selected release must contain exactly one \($checksum_name) asset")
  elif $archives[0].browser_download_url != $archive_url then
    error("unexpected archive URL for \($archive_name)")
  elif $checksums[0].browser_download_url != $checksum_url then
    error("unexpected checksum URL for \($checksum_name)")
  elif ($archives[0].digest != null and ($archives[0].digest | valid_digest | not)) then
    error("invalid archive digest for \($archive_name)")
  elif ($checksums[0].digest != null and ($checksums[0].digest | valid_digest | not)) then
    error("invalid checksum digest for \($checksum_name)")
  else
    {
      upstream_version: $tag,
      architecture: "amd64",
      archive_name: $archive_name,
      archive_url: $archive_url,
      checksum_name: $checksum_name,
      checksum_url: $checksum_url
    }
    + (if $archives[0].digest == null then {} else {archive_digest: $archives[0].digest} end)
    + (if $checksums[0].digest == null then {} else {checksum_digest: $checksums[0].digest} end)
  end
' <"$releases_file"
