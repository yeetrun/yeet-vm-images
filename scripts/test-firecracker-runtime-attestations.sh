#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs and GitHub expressions are intentionally literal.
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
writer="$repo_root/scripts/write-firecracker-runtime-attestation.sh"
canary_writer="$repo_root/scripts/write-firecracker-runtime-canary-attestation.sh"
publisher="$repo_root/scripts/publish-firecracker-runtime-attestation.sh"
harness="$repo_root/scripts/test-firecracker-runtime-kvm.sh"
canary_harness="$repo_root/scripts/test-firecracker-runtime-canary.sh"
guest_downloader="$repo_root/scripts/download-published-guest-base.sh"
guest_synthesizer="$repo_root/scripts/synthesize-firecracker-runtime-test-guest.sh"
schema="$repo_root/schemas/firecracker-runtime-attestation.schema.json"
fixture="$repo_root/scripts/testdata/runtime-attestation-integration.json"
canary_fixture="$repo_root/scripts/testdata/runtime-attestation-canary.json"
schema_validator="${CHECK_JSONSCHEMA:-$(command -v check-jsonschema || true)}"
if [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || { echo "missing check-jsonschema" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "Firecracker runtime attestation test failed: $*" >&2; exit 1; }
reject() { if "$@" >/dev/null 2>&1; then fail "command unexpectedly succeeded: $*"; fi; }

for path in "$writer" "$canary_writer" "$publisher" "$harness" "$canary_harness" "$guest_downloader" "$guest_synthesizer"; do
	[ -x "$path" ] || fail "missing executable ${path#"$repo_root/"}"
done

# The closed contract binds repository provenance and the exact Yeet code tested.
"$schema_validator" --schemafile "$schema" "$fixture" >/dev/null
"$schema_validator" --schemafile "$schema" "$canary_fixture" >/dev/null
jq -e '
  .tested_yeet == {
    repository: "yeetrun/yeet",
    commit: "76543210fedcba9876543210fedcba9876543210"
  } and
  .artifacts == {
    ubuntu_guest_release: "guest-ubuntu-26.04-amd64-v2",
    nixos_guest_release: "guest-nixos-26.05-amd64-v2",
    current_kernel_release: "kernel-linux-7.1.4-yeet-v4",
    previous_kernel_release: "kernel-linux-7.1.4-yeet-v3"
  } and
  (.matrix | keys == ["current_kernel", "custom_roots", "jailer_drop", "nixos", "previous_kernel", "raw", "ubuntu", "zfs"]) and
  all(.matrix[]; . == "passed")
' "$fixture" >/dev/null || fail "fixture does not bind all required evidence"

for mutation in missing-cell failed-result unknown-field missing-tested-yeet wrong-tested-repository latest-guest missing-artifact; do
	case "$mutation" in
		missing-cell) jq 'del(.matrix.zfs)' "$fixture" >"$tmp_dir/$mutation.json" ;;
		failed-result) jq '.result="failed"' "$fixture" >"$tmp_dir/$mutation.json" ;;
		unknown-field) jq '.tested_yeet.extra=true' "$fixture" >"$tmp_dir/$mutation.json" ;;
		missing-tested-yeet) jq 'del(.tested_yeet)' "$fixture" >"$tmp_dir/$mutation.json" ;;
		wrong-tested-repository) jq '.tested_yeet.repository="example/yeet"' "$fixture" >"$tmp_dir/$mutation.json" ;;
		latest-guest) jq '.artifacts.ubuntu_guest_release="ubuntu-26.04-amd64-latest"' "$fixture" >"$tmp_dir/$mutation.json" ;;
		missing-artifact) jq 'del(.artifacts.previous_kernel_release)' "$fixture" >"$tmp_dir/$mutation.json" ;;
	esac
	if "$schema_validator" --schemafile "$schema" "$tmp_dir/$mutation.json" >/dev/null 2>&1; then
		fail "schema accepted $mutation attestation"
	fi
done

for mutation in unknown-canary-field too-few-boots too-few-reboots too-few-restores short-soak incomplete-override; do
	case "$mutation" in
		unknown-canary-field) jq '.canary.extra=true' "$canary_fixture" >"$tmp_dir/$mutation.json" ;;
		too-few-boots) jq '.canary.boot_cycles=24' "$canary_fixture" >"$tmp_dir/$mutation.json" ;;
		too-few-reboots) jq '.canary.natural_reboots=9' "$canary_fixture" >"$tmp_dir/$mutation.json" ;;
		too-few-restores) jq '.canary.disk_restore_cycles=4' "$canary_fixture" >"$tmp_dir/$mutation.json" ;;
		short-soak) jq '.canary.soak_seconds=3600' "$canary_fixture" >"$tmp_dir/$mutation.json" ;;
		incomplete-override) jq '.canary.soak_seconds=3600 | .canary.emergency_override=true | .canary.emergency_approver="operator"' "$canary_fixture" >"$tmp_dir/$mutation.json" ;;
	esac
	if "$schema_validator" --schemafile "$schema" "$tmp_dir/$mutation.json" >/dev/null 2>&1; then
		fail "schema accepted $mutation canary attestation"
	fi
done
jq '.canary.soak_seconds=3600 | .canary.emergency_override=true | .canary.emergency_approver="operator" | .canary.emergency_reason="approved first-runtime bootstrap"' "$canary_fixture" >"$tmp_dir/emergency-canary.json"
"$schema_validator" --schemafile "$schema" "$tmp_dir/emergency-canary.json" >/dev/null

canary_matrix="$tmp_dir/canary-matrix.json"
jq '.matrix' "$canary_fixture" >"$canary_matrix"
written_canary="$tmp_dir/written-canary.json"
"$canary_writer" \
	--runtime-id firecracker-v1.16.1-yeet-v1 --manifest-sha256 "$(printf 'a%.0s' {1..64})" \
	--source-commit 89abcdef0123456789abcdef0123456789abcdef --workflow-run 123456790 \
	--yeet-commit 76543210fedcba9876543210fedcba9876543210 \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 --nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 --previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--matrix-file "$canary_matrix" --boot-cycles 25 --natural-reboots 10 --disk-restore-cycles 5 \
	--soak-seconds 86400 --emergency-override false --started-at 2026-07-19T14:00:00Z \
	--completed-at 2026-07-20T14:37:00Z --out "$written_canary"
cmp -s "$written_canary" "$canary_fixture" || fail "canary writer output differs from reviewed fixture"

matrix="$tmp_dir/matrix.json"
jq '.matrix' "$fixture" >"$matrix"
written="$tmp_dir/written.json"
"$writer" \
	--runtime-id firecracker-v1.16.1-yeet-v1 \
	--manifest-sha256 "$(printf 'a%.0s' {1..64})" \
	--source-commit 89abcdef0123456789abcdef0123456789abcdef \
	--workflow-run 123456789 \
	--yeet-commit 76543210fedcba9876543210fedcba9876543210 \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 \
	--nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 \
	--previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--matrix-file "$matrix" \
	--started-at 2026-07-19T14:00:00Z \
	--completed-at 2026-07-19T14:37:00Z \
	--out "$written"
cmp -s "$written" "$fixture" || fail "writer output differs from reviewed fixture"

reject "$writer" --runtime-id firecracker-v1.16.1-yeet-v1 \
	--manifest-sha256 "$(printf 'a%.0s' {1..64})" --source-commit 89abcdef0123456789abcdef0123456789abcdef \
	--workflow-run 123456789 --yeet-commit 76543210fedcba9876543210fedcba9876543210 \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 \
	--nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 \
	--previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--matrix-file "$tmp_dir/missing-cell.json" --started-at 2026-07-19T14:00:00Z \
	--completed-at 2026-07-19T14:37:00Z --out "$tmp_dir/rejected.json"
reject "$writer" --runtime-id firecracker-v1.16.1-yeet-v1 \
	--manifest-sha256 "$(printf 'a%.0s' {1..64})" --source-commit 89abcdef0123456789abcdef0123456789abcdef \
	--workflow-run 123456789 --yeet-commit 76543210fedcba9876543210fedcba9876543210 \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 \
	--nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 \
	--previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--matrix-file "$matrix" --started-at 2026-07-19T14:37:00Z \
	--completed-at 2026-07-19T14:00:00Z --out "$tmp_dir/rejected-time.json"

# The publisher requires the exact tag, checksum line, Actions identity, and a
# repository-scoped token. Its complete API transaction runs against a local
# command fixture; the production path is the path under test.
checksum="$tmp_dir/runtime-attestation.sha256"
sha256sum "$written" | awk '{print $1 "  runtime-attestation.json"}' >"$checksum"
publish_log="$tmp_dir/publish.log"
mkdir -p "$tmp_dir/publish-bin"
cat >"$tmp_dir/publish-bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$YEET_ATTESTATION_GH_LOG"
[ "$1" = api ] || exit 90; shift
include=false method="" endpoint="" input=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--include) include=true; shift ;;
		--method) method="$2"; shift 2 ;;
		--input) input="$2"; shift 2 ;;
		--header) shift 2 ;;
		*) [ -z "$endpoint" ] || exit 91; endpoint="$1"; shift ;;
	esac
done
[ "$include" = true ] && [ -n "$method" ] && [ -n "$endpoint" ] || exit 92
[ -n "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] || exit 93
scenario="${YEET_ATTESTATION_SCENARIO:-success}" state="$YEET_ATTESTATION_STATE"
target=89abcdef0123456789abcdef0123456789abcdef
tag=firecracker-v1.16.1-yeet-v1-integration-123456789
respond() { printf 'HTTP/2 %s OK\nETag: "fixture"\n\n%s\n' "$1" "$2"; }
asset_path() { case "$1" in runtime-attestation.json) printf '%s\n' "$YEET_ATTESTATION_FILE" ;; runtime-attestation.sha256) printf '%s\n' "$YEET_ATTESTATION_CHECKSUM" ;; esac; }
asset_json() {
	local name="$1" id path size digest url browser
	case "$name" in runtime-attestation.json) id=501 ;; runtime-attestation.sha256) id=502 ;; *) id=599 ;; esac
	path="$(asset_path "$name")"; size="$(wc -c <"$path" | tr -d ' ')"; digest="sha256:$(sha256sum "$path" | awk '{print $1}')"
	url="https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/$id"
	if [ -e "$state.published" ]; then
		browser="https://github.com/yeetrun/yeet-vm-images/releases/download/$tag/$name"
	else
		browser="https://github.com/yeetrun/yeet-vm-images/releases/download/untagged-49c39c20aae142532275/$name"
	fi
	[ "$scenario" != wrong-url ] || { url="https://api.github.com/repos/other/repo/releases/assets/$id"; browser="https://example.invalid/$name"; }
	[ "$scenario" != wrong-digest ] || digest="sha256:$(printf '0%.0s' {1..64})"
	[ "$scenario" != wrong-size ] || size=$((size + 1))
	jq -nc --arg name "$name" --argjson id "$id" --argjson size "$size" --arg digest "$digest" --arg url "$url" --arg browser "$browser" '{id:$id,name:$name,state:"uploaded",size:$size,digest:$digest,url:$url,browser_download_url:$browser}'
}
case "$method $endpoint" in
	"GET repos/yeetrun/yeet-vm-images/immutable-releases")
		[ "$scenario" != immutable-disabled ] && enabled=true || enabled=false; respond 200 "{\"enabled\":$enabled}" ;;
	"POST repos/yeetrun/yeet-vm-images/git/refs")
		[ "$scenario" != tag-collision ] || exit 1
		jq -e --arg target "$target" --arg tag "$tag" '.ref==("refs/tags/"+$tag) and .sha==$target' "$input" >/dev/null || exit 94
		: >"$state.tag"; respond 201 "{\"object\":{\"type\":\"commit\",\"sha\":\"$target\"}}" ;;
	"GET repos/yeetrun/yeet-vm-images/git/ref/tags/$tag")
		sha="$target"; [ "$scenario" != tag-race ] || sha=0000000000000000000000000000000000000000
		respond 200 "{\"object\":{\"type\":\"commit\",\"sha\":\"$sha\"}}" ;;
	"POST repos/yeetrun/yeet-vm-images/releases")
		: >"$state.release"; respond 201 '{"id":42,"upload_url":"https://uploads.github.com/repos/yeetrun/yeet-vm-images/releases/42/assets{?name,label}"}' ;;
	POST\ https://uploads.github.com/repos/yeetrun/yeet-vm-images/releases/42/assets\?name=*)
		name="${endpoint##*name=}"; count="$(wc -l <"$state.uploads" 2>/dev/null || echo 0)"
		if [ "$scenario" = upload-failure ] && [ "$count" -eq 1 ]; then exit 1; fi
		printf '%s\n' "$name" >>"$state.uploads"; respond 201 "$(asset_json "$name")" ;;
	"GET repos/yeetrun/yeet-vm-images/releases/42/assets?per_page=100&page=1")
		assets="$(for name in runtime-attestation.json runtime-attestation.sha256; do asset_json "$name"; done)"
		if [ "$scenario" = extra-asset ]; then assets="$assets
{\"id\":599,\"name\":\"extra\",\"state\":\"uploaded\",\"size\":1,\"digest\":\"sha256:$(printf '0%.0s' {1..64})\",\"url\":\"https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/599\",\"browser_download_url\":\"https://github.com/yeetrun/yeet-vm-images/releases/download/$tag/extra\"}"; fi
		respond 200 "$(jq -sc . <<<"$assets")" ;;
	"GET repos/yeetrun/yeet-vm-images/releases/42")
		if [ -e "$state.published" ]; then immutable=true; [ "$scenario" != mutable-final ] || immutable=false; respond 200 "{\"id\":42,\"tag_name\":\"$tag\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-07-19T20:00:00Z\",\"immutable\":$immutable}"
		else respond 200 "{\"id\":42,\"tag_name\":\"$tag\",\"draft\":true,\"prerelease\":false,\"published_at\":null,\"immutable\":false}"; fi ;;
	"PATCH repos/yeetrun/yeet-vm-images/releases/42") : >"$state.published"; respond 200 '{"id":42,"draft":false}' ;;
	*) echo "unexpected fixture API call: $method $endpoint" >&2; exit 99 ;;
esac
MOCK_GH
chmod +x "$tmp_dir/publish-bin/gh"
publisher_env=(env "PATH=$tmp_dir/publish-bin:$PATH" "CHECK_JSONSCHEMA=$schema_validator" \
	"YEET_ATTESTATION_GH_LOG=$publish_log" "YEET_ATTESTATION_FILE=$written" "YEET_ATTESTATION_CHECKSUM=$checksum" \
	GITHUB_ACTIONS=true GITHUB_REPOSITORY=yeetrun/yeet-vm-images \
	GITHUB_JOB=publish-firecracker-runtime-integration \
	GITHUB_WORKFLOW_REF=yeetrun/yeet-vm-images/.github/workflows/test-firecracker-runtime-kvm.yml@refs/heads/main \
	GITHUB_SHA=89abcdef0123456789abcdef0123456789abcdef GITHUB_RUN_ID=123456789 \
	YEET_INTEGRATION_WORKFLOW_REPOSITORY=yeetrun/yeet-vm-images \
	YEET_INTEGRATION_WORKFLOW_FILE_PATH=.github/workflows/test-firecracker-runtime-kvm.yml \
	YEET_INTEGRATION_WORKFLOW_REF=yeetrun/yeet-vm-images/.github/workflows/test-firecracker-runtime-kvm.yml@refs/heads/main \
	YEET_INTEGRATION_WORKFLOW_SHA=89abcdef0123456789abcdef0123456789abcdef GH_TOKEN=fixture-token)
run_publisher() {
	local scenario="$1" attestation_file="${2:-$written}" checksum_file="${3:-$checksum}" state
	state="$tmp_dir/attestation-$scenario"
	mkdir "$state"; : >"$state.uploads"
	YEET_ATTESTATION_SCENARIO="$scenario" YEET_ATTESTATION_STATE="$state" "${publisher_env[@]}" \
		"YEET_ATTESTATION_FILE=$attestation_file" "YEET_ATTESTATION_CHECKSUM=$checksum_file" \
		"$publisher" --runtime-id firecracker-v1.16.1-yeet-v1 \
		--manifest-sha256 "$(printf 'a%.0s' {1..64})" \
		--target 89abcdef0123456789abcdef0123456789abcdef \
		--run-id 123456789 --yeet-commit 76543210fedcba9876543210fedcba9876543210 \
		--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 \
		--nixos-guest-release guest-nixos-26.05-amd64-v2 \
		--current-kernel-release kernel-linux-7.1.4-yeet-v4 \
		--previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
		--attestation "$attestation_file" --checksum "$checksum_file"
}
: >"$publish_log"; run_publisher success
grep -Fq 'PATCH repos/yeetrun/yeet-vm-images/releases/42' "$publish_log" || fail "publisher did not publish by exact release ID"
for scenario in immutable-disabled tag-collision tag-race upload-failure extra-asset wrong-url wrong-digest wrong-size mutable-final; do
	: >"$publish_log"
	if run_publisher "$scenario" >/dev/null 2>&1; then fail "publisher accepted remote metadata scenario: $scenario"; fi
	done
reversed_attestation="$tmp_dir/reversed-attestation.json"
reversed_checksum="$tmp_dir/reversed-attestation.sha256"
jq '.started_at="2026-07-19T14:37:00Z" | .completed_at="2026-07-19T14:00:00Z"' "$written" >"$reversed_attestation"
printf '%s  runtime-attestation.json\n' "$(sha256sum "$reversed_attestation" | awk '{print $1}')" >"$reversed_checksum"
if run_publisher reversed-time "$reversed_attestation" "$reversed_checksum" >/dev/null 2>&1; then
	fail "publisher accepted evidence whose completion precedes its start"
fi
reject "${publisher_env[@]}" GITHUB_JOB=unreviewed-job "$publisher" \
	--runtime-id firecracker-v1.16.1-yeet-v1 --manifest-sha256 "$(printf 'a%.0s' {1..64})" \
	--target 89abcdef0123456789abcdef0123456789abcdef --run-id 123456789 \
	--yeet-commit 76543210fedcba9876543210fedcba9876543210 \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 \
	--nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 \
	--previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--attestation "$written" --checksum "$checksum"
reject "${publisher_env[@]}" "$publisher" \
	--runtime-id firecracker-v1.16.1-yeet-v1 --manifest-sha256 "$(printf 'a%.0s' {1..64})" \
	--target 89abcdef0123456789abcdef0123456789abcdef --run-id 123456789 \
	--yeet-commit 0000000000000000000000000000000000000000 \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 \
	--nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 \
	--previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--attestation "$written" --checksum "$checksum"

# The KVM orchestration is fixture-driven here; live KVM execution is reserved
# for the labeled runner. Every case receives exact immutable release IDs and
# the shared lifecycle assertions. No direct Firecracker launch is exposed.
bin_dir="$tmp_dir/bin"
mkdir "$bin_dir"
case_log="$tmp_dir/cases.log"
for helper in verify-runtime download-runtime download-guest download-kernel synthesize-guest; do
	printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "%%s\\n" "$*" >>"$YEET_KVM_HELPER_LOG"\n' >"$bin_dir/$helper"
	chmod +x "$bin_dir/$helper"
done
printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "%%s\\n" "$*" >>"$YEET_KVM_CASE_LOG"\n' >"$bin_dir/run-case"
chmod +x "$bin_dir/run-case"
matrix_out="$tmp_dir/kvm-matrix.json"
reject env YEET_KVM_VERIFY_RUNTIME="$bin_dir/verify-runtime" \
	"$harness" \
	--runtime-release firecracker-v1.16.1-yeet-v1 \
	--runtime-manifest-sha256 "$(printf 'a%.0s' {1..64})" \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 \
	--nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 \
	--previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--yeet-ref 76543210fedcba9876543210fedcba9876543210 \
	--work-dir "$tmp_dir/kvm-rejected-work" --matrix-out "$tmp_dir/kvm-rejected-matrix.json"
env YEET_RUNTIME_KVM_TEST_MODE=1 \
	YEET_KVM_VERIFY_RUNTIME="$bin_dir/verify-runtime" \
	YEET_KVM_DOWNLOAD_RUNTIME="$bin_dir/download-runtime" \
	YEET_KVM_DOWNLOAD_GUEST="$bin_dir/download-guest" \
	YEET_KVM_DOWNLOAD_KERNEL="$bin_dir/download-kernel" \
	YEET_KVM_SYNTHESIZE_GUEST="$bin_dir/synthesize-guest" \
	YEET_KVM_CASE_RUNNER="$bin_dir/run-case" YEET_KVM_CASE_LOG="$case_log" \
	YEET_KVM_HELPER_LOG="$tmp_dir/helpers.log" \
	"$harness" \
	--runtime-release firecracker-v1.16.1-yeet-v1 \
	--runtime-manifest-sha256 "$(printf 'a%.0s' {1..64})" \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 \
	--nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 \
	--previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--yeet-ref 76543210fedcba9876543210fedcba9876543210 \
	--work-dir "$tmp_dir/kvm-work" --matrix-out "$matrix_out"
[ "$(wc -l <"$case_log" | tr -d ' ')" = 7 ] || fail "KVM harness did not run seven representative scenarios"
[ "$(grep -Fc -- "--guest-dir" "$tmp_dir/helpers.log")" = 2 ] || fail "KVM harness did not synthesize exactly two component guests"
for scenario in ubuntu-current nixos-current previous-kernel raw-storage zfs-storage custom-roots jailer-drop; do
	grep -Fq -- "--scenario $scenario" "$case_log" || fail "KVM harness omitted $scenario"
done
for assertion in api-ready boot natural-reboot network-ready disk-snapshot-restore cleanup jailer-uid-gid-drop no-memory-snapshot; do
	[ "$(grep -Fc -- "--assert $assertion" "$case_log")" = 7 ] || fail "shared assertion missing from a scenario: $assertion"
done
[ "$(grep -Fc -- "--test-user yeet-vm" "$case_log")" = 7 ] || fail "KVM harness did not require the production yeet-vm runtime identity"
if grep -Eq '(^| )firecracker( |$)|direct-firecracker' "$case_log"; then fail "KVM harness exposed a direct Firecracker fallback"; fi
jq -e 'keys == ["current_kernel", "custom_roots", "jailer_drop", "nixos", "previous_kernel", "raw", "ubuntu", "zfs"] and all(.[]; . == "passed")' "$matrix_out" >/dev/null

cat >"$bin_dir/canary-kvm" <<'MOCK_CANARY_KVM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$YEET_CANARY_CALL_LOG"
matrix=""
while [ "$#" -gt 0 ]; do
	case "$1" in --matrix-out) matrix="$2"; shift 2 ;; *) shift ;; esac
done
jq -n '{ubuntu:"passed",nixos:"passed",current_kernel:"passed",previous_kernel:"passed",raw:"passed",zfs:"passed",custom_roots:"passed",jailer_drop:"passed"}' >"$matrix"
MOCK_CANARY_KVM
chmod +x "$bin_dir/canary-kvm"
canary_evidence="$tmp_dir/canary-evidence.json"
YEET_RUNTIME_CANARY_TEST_MODE=1 YEET_CANARY_KVM_HARNESS="$bin_dir/canary-kvm" YEET_CANARY_CALL_LOG="$tmp_dir/canary-calls.log" \
	"$canary_harness" --runtime-release firecracker-v1.16.1-yeet-v1 \
	--runtime-manifest-sha256 "$(printf 'a%.0s' {1..64})" \
	--ubuntu-guest-release guest-ubuntu-26.04-amd64-v2 --nixos-guest-release guest-nixos-26.05-amd64-v2 \
	--current-kernel-release kernel-linux-7.1.4-yeet-v4 --previous-kernel-release kernel-linux-7.1.4-yeet-v3 \
	--yeet-ref 76543210fedcba9876543210fedcba9876543210 --work-dir "$tmp_dir/canary-work" --evidence-out "$canary_evidence"
[ "$(wc -l <"$tmp_dir/canary-calls.log"|tr -d ' ')" = 5 ] || fail "canary did not execute five full KVM matrices"
jq -e '.boot_cycles>=25 and .natural_reboots>=10 and .disk_restore_cycles>=5 and .functional_cycles==5 and all(.matrix[];.=="passed")' "$canary_evidence" >/dev/null || fail "canary counters are insufficient"

echo "Firecracker runtime attestation and KVM orchestration verified"
