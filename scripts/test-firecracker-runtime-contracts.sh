#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq interpolation is intentionally protected from the shell.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

runtime_catalog_verifier="$repo_root/scripts/verify-runtime-catalog.sh"
runtime_manifest="$repo_root/scripts/testdata/runtime-manifest-v1.16.1.json"
runtime_catalog_fixture="$repo_root/scripts/testdata/runtime-catalog-empty.json"
runtime_attestation="$repo_root/scripts/testdata/runtime-attestation-integration.json"
manifest_schema="$repo_root/schemas/firecracker-runtime-manifest.schema.json"
catalog_schema="$repo_root/schemas/firecracker-runtime-catalog.schema.json"
attestation_schema="$repo_root/schemas/firecracker-runtime-attestation.schema.json"

for artifact in \
	"$manifest_schema" \
	"$catalog_schema" \
	"$attestation_schema" \
	"$repo_root/runtime-catalog.json" \
	"$runtime_catalog_verifier" \
	"$runtime_manifest" \
	"$runtime_catalog_fixture" \
	"$runtime_attestation"; do
	if [ ! -e "$artifact" ]; then
		echo "missing required runtime contract artifact: $artifact" >&2
		exit 1
	fi
done

schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ]; then
	if command -v check-jsonschema >/dev/null 2>&1; then
		schema_validator="$(command -v check-jsonschema)"
	elif command -v mise >/dev/null 2>&1; then
		schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"
	fi
fi
if [ -z "$schema_validator" ] || [ ! -x "$schema_validator" ]; then
	echo "missing required command: check-jsonschema (run 'mise install')" >&2
	exit 1
fi

schema_validate() {
	local schema="$1"
	local instance="$2"
	"$schema_validator" --schemafile "$schema" "$instance" >/dev/null
}

manifest_filter='
  def sha256: type == "string" and test("^[0-9a-f]{64}$");
  def commit: type == "string" and test("^[0-9a-f]{40}$");
  (.runtime_id | capture("^firecracker-(?<version>v[0-9]+[.][0-9]+[.][0-9]+)-yeet-v[1-9][0-9]*$").version) as $version |
  .schema_version == 1 and
  .architecture == "amd64" and
  .upstream.repository == "firecracker-microvm/firecracker" and
  .upstream.version == $version and
  .upstream.tag == $version and
  (.upstream.commit | commit) and
  .upstream.archive_url == "https://github.com/firecracker-microvm/firecracker/releases/download/\($version)/firecracker-\($version)-x86_64.tgz" and
  (.upstream.archive_sha256 | sha256) and
  .upstream.checksum_url == "https://github.com/firecracker-microvm/firecracker/releases/download/\($version)/firecracker-\($version)-x86_64.tgz.sha256.txt" and
  (.upstream.tag_signature.status == "signed" or
    .upstream.tag_signature.status == "unsigned-approved" or
    .upstream.tag_signature.status == "signer-rotation-approved") and
  (if .upstream.tag_signature.status == "unsigned-approved"
   then .upstream.tag_signature.fingerprint == null
   else (.upstream.tag_signature.fingerprint | type == "string" and test("^([0-9A-F]{40}|[0-9A-F]{64})$"))
   end) and
  .components.firecracker.path == "firecracker" and
  (.components.firecracker.sha256 | sha256) and
  .components.firecracker.version_output == "Firecracker \($version)" and
  .components.jailer.path == "jailer" and
  (.components.jailer.sha256 | sha256) and
  .components.jailer.version_output == "Jailer \($version)" and
  .classification.production_release == true and
  .classification.default_seccomp == true and
  (.support.state == "supported" or .support.state == "deprecated" or .support.state == "eol" or .support.state == "revoked") and
  .support.policy_url == "https://github.com/firecracker-microvm/firecracker/blob/main/docs/RELEASE_POLICY.md" and
  .provenance.repository == "yeetrun/yeet-vm-images" and
  (.provenance.commit | commit) and
  (.provenance.workflow_run | type == "string" and test("^[1-9][0-9]*$"))'

attestation_filter='
  def sha256: type == "string" and test("^[0-9a-f]{64}$");
  def commit: type == "string" and test("^[0-9a-f]{40}$");
  .schema_version == 1 and
  .kind == "integration" and
  (.subject.runtime_id | type == "string" and test("^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$")) and
  (.subject.manifest_sha256 | sha256) and
  .runner.class == "self-hosted-linux-kvm" and
  .runner.architecture == "amd64" and
  .source.repository == "yeetrun/yeet-vm-images" and
  (.source.commit | commit) and
  (.source.workflow_run | type == "string" and test("^[1-9][0-9]*$")) and
  .tested_yeet.repository == "yeetrun/yeet" and
  (.tested_yeet.commit | commit) and
  (.artifacts | keys == ["current_kernel_release", "nixos_guest_release", "previous_kernel_release", "ubuntu_guest_release"]) and
  (.artifacts.ubuntu_guest_release | test("^ubuntu-[0-9]+[.][0-9]+-amd64-(kernel-[0-9]+[.][0-9]+([.][0-9]+)*-)?v[1-9][0-9]*$")) and
  (.artifacts.nixos_guest_release | test("^nixos-[0-9]+[.][0-9]+-amd64-(kernel-[0-9]+[.][0-9]+([.][0-9]+)*-)?v[1-9][0-9]*$")) and
  (.artifacts.current_kernel_release | test("^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$")) and
  (.artifacts.previous_kernel_release | test("^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$")) and
  (.matrix | keys == ["current_kernel", "custom_roots", "jailer_drop", "nixos", "previous_kernel", "raw", "ubuntu", "zfs"]) and
  all(.matrix[]; . == "passed") and
  (.started_at | type == "string" and fromdateiso8601) and
  (.completed_at | type == "string" and fromdateiso8601) and
  .result == "passed"'

assert_catalog_schema_rejected() {
	local name="$1"
	local path="$2"
	if schema_validate "$catalog_schema" "$path" 2>/dev/null; then
		echo "runtime catalog schema accepted invalid mutation: $name" >&2
		exit 1
	fi
	if "$runtime_catalog_verifier" "$path" >/dev/null 2>&1; then
		echo "runtime catalog verifier accepted schema-invalid mutation: $name" >&2
		exit 1
	fi
}

assert_catalog_cross_field_rejected() {
	local name="$1"
	local path="$2"
	if ! schema_validate "$catalog_schema" "$path"; then
		echo "runtime catalog cross-field mutation unexpectedly failed schema validation: $name" >&2
		exit 1
	fi
	if "$runtime_catalog_verifier" "$path" >/dev/null 2>&1; then
		echo "runtime catalog verifier accepted invalid mutation: $name" >&2
		exit 1
	fi
}

assert_manifest_schema_rejected() {
	local name="$1"
	local path="$2"
	if schema_validate "$manifest_schema" "$path" 2>/dev/null; then
		echo "runtime manifest schema accepted invalid mutation: $name" >&2
		exit 1
	fi
}

assert_manifest_schema_and_filter_rejected() {
	local name="$1"
	local path="$2"
	assert_manifest_schema_rejected "$name" "$path"
	if jq -e "$manifest_filter" "$path" >/dev/null 2>&1; then
		echo "runtime manifest cross-field validator accepted invalid mutation: $name" >&2
		exit 1
	fi
}

assert_manifest_cross_field_rejected() {
	local name="$1"
	local path="$2"
	if ! schema_validate "$manifest_schema" "$path"; then
		echo "runtime manifest cross-field mutation unexpectedly failed schema validation: $name" >&2
		exit 1
	fi
	if jq -e "$manifest_filter" "$path" >/dev/null 2>&1; then
		echo "runtime manifest cross-field validator accepted invalid mutation: $name" >&2
		exit 1
	fi
}

assert_attestation_schema_rejected() {
	local name="$1"
	local path="$2"
	if schema_validate "$attestation_schema" "$path" 2>/dev/null; then
		echo "runtime attestation schema accepted invalid mutation: $name" >&2
		exit 1
	fi
}

"$schema_validator" --check-metaschema \
	"$manifest_schema" \
	"$catalog_schema" \
	"$attestation_schema" >/dev/null
schema_validate "$catalog_schema" "$runtime_catalog_fixture"
schema_validate "$catalog_schema" "$repo_root/runtime-catalog.json"
"$runtime_catalog_verifier" "$runtime_catalog_fixture"
"$runtime_catalog_verifier" "$repo_root/runtime-catalog.json"
schema_validate "$manifest_schema" "$runtime_manifest"
schema_validate "$attestation_schema" "$runtime_attestation"
jq -e "$manifest_filter" "$runtime_manifest" >/dev/null
jq -e "$attestation_filter" "$runtime_attestation" >/dev/null

jq -e '.schema_version == 1 and .runtime_id == "firecracker-v1.16.1-yeet-v1"' \
	"$runtime_manifest" >/dev/null
jq -e '.schema_version == 1 and .kind == "integration" and (.subject.manifest_sha256 | test("^[0-9a-f]{64}$"))' \
	"$runtime_attestation" >/dev/null

jq -e '
  ."$schema" == "https://json-schema.org/draft/2020-12/schema" and
  .additionalProperties == false and
  .properties.schema_version.const == 1 and
  .properties.architecture.const == "amd64" and
  .properties.runtime_id.pattern == "^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$" and
  .properties.upstream.additionalProperties == false and
  .properties.components.additionalProperties == false and
  .properties.classification.additionalProperties == false and
  .properties.classification.properties.production_release.const == true and
  .properties.classification.properties.default_seccomp.const == true and
  .properties.support.additionalProperties == false and
  .properties.provenance.additionalProperties == false
' "$manifest_schema" >/dev/null
jq -e '
  ."$schema" == "https://json-schema.org/draft/2020-12/schema" and
  .additionalProperties == false and
  .properties.schema_version.const == 1 and
  .properties.architectures.additionalProperties == false and
  (.properties.architectures.required == ["amd64"]) and
  .properties.revocations.type == "array"
' "$catalog_schema" >/dev/null
jq -e '
  ."$schema" == "https://json-schema.org/draft/2020-12/schema" and
  .additionalProperties == false and
  .properties.schema_version.const == 1 and
  .properties.kind.const == "integration" and
  .properties.subject.additionalProperties == false and
  .properties.runner.additionalProperties == false and
  .properties.source.additionalProperties == false and
  .properties.tested_yeet.additionalProperties == false and
  .properties.artifacts.additionalProperties == false and
  .properties.matrix.additionalProperties == false
' "$attestation_schema" >/dev/null

runtime_a='{
  "runtime_id": "firecracker-v1.16.1-yeet-v1",
  "manifest_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.16.1-yeet-v1/runtime-manifest.json",
  "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "upstream_version": "v1.16.1",
  "support": "supported",
  "integration_attestation_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.16.1-yeet-v1-integration-123456789/runtime-attestation.json",
  "integration_attestation_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "canary_attestation_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.16.1-yeet-v1-canary-123456790/runtime-attestation.json",
  "canary_attestation_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}'
runtime_revoked='{
  "runtime_id": "firecracker-v1.15.0-yeet-v1",
  "manifest_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.15.0-yeet-v1/runtime-manifest.json",
  "manifest_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  "upstream_version": "v1.15.0",
  "support": "revoked",
  "integration_attestation_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.15.0-yeet-v1-integration-123456780/runtime-attestation.json",
  "integration_attestation_sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "canary_attestation_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.15.0-yeet-v1-canary-123456781/runtime-attestation.json",
  "canary_attestation_sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
}'

jq -n --argjson runtime "$runtime_a" --argjson revoked "$runtime_revoked" '{
  schema_version: 1,
  architectures: {
    amd64: {
      runtimes: [$runtime, $revoked],
      channels: {
        stable: {runtime_id: $runtime.runtime_id, manifest_sha256: $runtime.manifest_sha256},
        candidate: {runtime_id: $runtime.runtime_id, manifest_sha256: $runtime.manifest_sha256}
      }
    }
  },
  revocations: [{
    runtime_id: $revoked.runtime_id,
    manifest_sha256: $revoked.manifest_sha256,
    reason: "Known-bad test fixture",
    recorded_at: "2026-07-19T12:00:00Z"
  }]
}' >"$tmp_dir/valid-catalog.json"
schema_validate "$catalog_schema" "$tmp_dir/valid-catalog.json"
"$runtime_catalog_verifier" "$tmp_dir/valid-catalog.json"

jq '.architectures.amd64.channels.stable = null
  | .architectures.amd64.runtimes[0].canary_attestation_url = null
  | .architectures.amd64.runtimes[0].canary_attestation_sha256 = null' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/valid-candidate-catalog.json"
schema_validate "$catalog_schema" "$tmp_dir/valid-candidate-catalog.json"
"$runtime_catalog_verifier" "$tmp_dir/valid-candidate-catalog.json"

jq '.architectures.amd64.channels.candidate.manifest_sha256 = ("0" * 64)' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/mismatched-pair.json"
assert_catalog_cross_field_rejected "mismatched channel pair" "$tmp_dir/mismatched-pair.json"

jq '.architectures.amd64.runtimes[0].manifest_sha256 = "not-a-sha256"' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/invalid-sha256.json"
assert_catalog_schema_rejected "invalid SHA-256" "$tmp_dir/invalid-sha256.json"

jq '.architectures.arm64 = .architectures.amd64 | del(.architectures.amd64)' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/unsupported-architecture.json"
assert_catalog_schema_rejected "unsupported architecture" "$tmp_dir/unsupported-architecture.json"

jq '.architectures.amd64.runtimes[0].manifest_url |= sub("^https"; "http")' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/http-url.json"
assert_catalog_schema_rejected "HTTP manifest URL" "$tmp_dir/http-url.json"

jq '.architectures.amd64.runtimes[0].integration_attestation_url = "https://example.invalid/runtime-attestation.json"' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/wrong-attestation-url.json"
assert_catalog_schema_rejected "wrong attestation URL" "$tmp_dir/wrong-attestation-url.json"

jq '.unexpected = "hostile"' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/catalog-unknown-root-field.json"
assert_catalog_schema_rejected "catalog unknown root field" "$tmp_dir/catalog-unknown-root-field.json"

jq '.architectures.amd64.channels.unexpected = null' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/catalog-unknown-nested-field.json"
assert_catalog_schema_rejected "catalog unknown nested field" "$tmp_dir/catalog-unknown-nested-field.json"

jq '.revocations += [.revocations[0]]' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/duplicate-revocation.json"
assert_catalog_cross_field_rejected "duplicate revocation" "$tmp_dir/duplicate-revocation.json"

jq 'del(.architectures.amd64.runtimes[0].integration_attestation_sha256)' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/missing-attestation-digest.json"
assert_catalog_schema_rejected "missing attestation digest" "$tmp_dir/missing-attestation-digest.json"

jq '.architectures.amd64.runtimes += [(.architectures.amd64.runtimes[0] | .manifest_sha256 = ("9" * 64))]
  | .architectures.amd64.channels.candidate.manifest_sha256 = ("9" * 64)' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/aliased-channels-different-digests.json"
assert_catalog_cross_field_rejected "stable/candidate aliasing with different manifest digests" "$tmp_dir/aliased-channels-different-digests.json"

jq '.architectures.amd64.runtimes += [(
    .architectures.amd64.runtimes[0]
    | .manifest_sha256 = ("8" * 64)
    | .support = "revoked"
  )]
  | .revocations += [{
      runtime_id: .architectures.amd64.runtimes[0].runtime_id,
      manifest_sha256: ("8" * 64),
      reason: "Split-digest revocation test fixture",
      recorded_at: "2026-07-19T12:00:00Z"
    }]' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/split-digest-revocation.json"
assert_catalog_cross_field_rejected "same runtime ID split across channeled and revoked digests" "$tmp_dir/split-digest-revocation.json"

jq '.architectures.amd64.runtimes[0].upstream_version = "1.16"' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/invalid-version.json"
assert_catalog_schema_rejected "invalid upstream version" "$tmp_dir/invalid-version.json"

jq '.architectures.amd64.runtimes[0].support = "experimental"' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/invalid-support.json"
assert_catalog_schema_rejected "unknown support status" "$tmp_dir/invalid-support.json"

jq '.architectures.amd64.runtimes += [.architectures.amd64.runtimes[0]]' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/duplicate-runtime.json"
assert_catalog_cross_field_rejected "duplicate runtime ID" "$tmp_dir/duplicate-runtime.json"

jq '.architectures.amd64.runtimes[0].integration_attestation_url = null
  | .architectures.amd64.runtimes[0].integration_attestation_sha256 = null' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/candidate-missing-integration.json"
assert_catalog_cross_field_rejected "candidate missing integration evidence" "$tmp_dir/candidate-missing-integration.json"

jq '.architectures.amd64.channels.candidate = null
  | .architectures.amd64.runtimes[0].integration_attestation_url = null
  | .architectures.amd64.runtimes[0].integration_attestation_sha256 = null' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/stable-missing-integration.json"
assert_catalog_cross_field_rejected "stable missing integration evidence" "$tmp_dir/stable-missing-integration.json"

jq '.architectures.amd64.runtimes[0].canary_attestation_url = null
  | .architectures.amd64.runtimes[0].canary_attestation_sha256 = null' \
	"$tmp_dir/valid-catalog.json" >"$tmp_dir/stable-missing-canary.json"
assert_catalog_cross_field_rejected "stable missing canary evidence" "$tmp_dir/stable-missing-canary.json"

jq '.architectures.amd64.channels.candidate = {
  runtime_id: .architectures.amd64.runtimes[1].runtime_id,
  manifest_sha256: .architectures.amd64.runtimes[1].manifest_sha256
}' "$tmp_dir/valid-catalog.json" >"$tmp_dir/revoked-channel.json"
assert_catalog_cross_field_rejected "revoked channel entry" "$tmp_dir/revoked-channel.json"

jq '.components.firecracker.sha256 = "ABCDEF"' \
	"$runtime_manifest" >"$tmp_dir/invalid-manifest-sha256.json"
assert_manifest_schema_and_filter_rejected "invalid artifact SHA-256" "$tmp_dir/invalid-manifest-sha256.json"

jq '.runtime_id = "firecracker-v1.16.2-yeet-v1"' \
	"$runtime_manifest" >"$tmp_dir/mismatched-manifest-version.json"
assert_manifest_cross_field_rejected "runtime ID and upstream version mismatch" "$tmp_dir/mismatched-manifest-version.json"

jq '.components.jailer.version_output = "Jailer v1.16.0"' \
	"$runtime_manifest" >"$tmp_dir/mismatched-component-version.json"
assert_manifest_cross_field_rejected "component and upstream version mismatch" "$tmp_dir/mismatched-component-version.json"

jq '.classification.default_seccomp = false' \
	"$runtime_manifest" >"$tmp_dir/manifest-non-default-seccomp.json"
assert_manifest_schema_and_filter_rejected "manifest non-default seccomp classification" "$tmp_dir/manifest-non-default-seccomp.json"

jq '.classification.production_release = false' \
	"$runtime_manifest" >"$tmp_dir/manifest-non-production-release.json"
assert_manifest_schema_and_filter_rejected "manifest non-production classification" "$tmp_dir/manifest-non-production-release.json"

jq '.unexpected = "hostile"' \
	"$runtime_manifest" >"$tmp_dir/manifest-unknown-root-field.json"
assert_manifest_schema_rejected "manifest unknown root field" "$tmp_dir/manifest-unknown-root-field.json"

jq '.components.firecracker.unexpected = "hostile"' \
	"$runtime_manifest" >"$tmp_dir/manifest-unknown-nested-field.json"
assert_manifest_schema_rejected "manifest unknown nested field" "$tmp_dir/manifest-unknown-nested-field.json"

jq 'del(.subject.manifest_sha256)' \
	"$runtime_attestation" >"$tmp_dir/missing-attestation-subject-digest.json"
assert_attestation_schema_rejected "missing attestation subject digest" "$tmp_dir/missing-attestation-subject-digest.json"

jq 'del(.matrix.jailer_drop)' \
	"$runtime_attestation" >"$tmp_dir/missing-attestation-matrix-cell.json"
assert_attestation_schema_rejected "missing integration matrix cell" "$tmp_dir/missing-attestation-matrix-cell.json"

jq 'del(.tested_yeet)' \
	"$runtime_attestation" >"$tmp_dir/missing-tested-yeet.json"
assert_attestation_schema_rejected "missing tested Yeet identity" "$tmp_dir/missing-tested-yeet.json"

jq '.artifacts.ubuntu_guest_release = "ubuntu-26.04-amd64-latest"' \
	"$runtime_attestation" >"$tmp_dir/mutable-guest-alias.json"
assert_attestation_schema_rejected "mutable guest alias" "$tmp_dir/mutable-guest-alias.json"

jq '.artifacts.ubuntu_guest_release = "ubuntu-24.04-amd64-v11"
  | .artifacts.nixos_guest_release = "nixos-24.11-amd64-v15"' \
	"$runtime_attestation" >"$tmp_dir/legacy-immutable-guests.json"
schema_validate "$attestation_schema" "$tmp_dir/legacy-immutable-guests.json"

jq '.unexpected = "hostile"' \
	"$runtime_attestation" >"$tmp_dir/attestation-unknown-root-field.json"
assert_attestation_schema_rejected "attestation unknown root field" "$tmp_dir/attestation-unknown-root-field.json"

jq '.subject.unexpected = "hostile"' \
	"$runtime_attestation" >"$tmp_dir/attestation-unknown-nested-field.json"
assert_attestation_schema_rejected "attestation unknown nested field" "$tmp_dir/attestation-unknown-nested-field.json"

echo "Firecracker runtime contracts verified"
