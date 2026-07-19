#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
script_dir="${script_source%/*}"
if [ "$script_dir" = "$script_source" ]; then
	script_dir="."
fi
repo_root="$(cd "$script_dir/.." && pwd)"
catalog="${1:-$repo_root/runtime-catalog.json}"

if ! command -v jq >/dev/null 2>&1; then
	echo "missing required command: jq" >&2
	exit 1
fi
if [ ! -f "$catalog" ]; then
	echo "runtime catalog does not exist: $catalog" >&2
	exit 1
fi

if ! jq -e '
  def runtime_id:
    type == "string" and
    test("^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$");
  def sha256:
    type == "string" and test("^[0-9a-f]{64}$");
  def version:
    type == "string" and test("^v[0-9]+[.][0-9]+[.][0-9]+$");
  def manifest_url($runtime_id):
    . == ("https://github.com/yeetrun/yeet-vm-images/releases/download/" +
      $runtime_id + "/runtime-manifest.json");
  def integration_url($runtime_id):
    type == "string" and
    startswith("https://github.com/yeetrun/yeet-vm-images/releases/download/" +
      $runtime_id + "-integration-") and
    (ltrimstr("https://github.com/yeetrun/yeet-vm-images/releases/download/" +
      $runtime_id + "-integration-") |
      test("^[1-9][0-9]*/runtime-attestation[.]json$"));
  def canary_url($runtime_id):
    type == "string" and
    startswith("https://github.com/yeetrun/yeet-vm-images/releases/download/" +
      $runtime_id + "-canary-") and
    (ltrimstr("https://github.com/yeetrun/yeet-vm-images/releases/download/" +
      $runtime_id + "-canary-") |
      test("^[1-9][0-9]*/runtime-attestation[.]json$"));
  def pointer:
    type == "object" and
    (keys == ["manifest_sha256", "runtime_id"]) and
    (.runtime_id | runtime_id) and
    (.manifest_sha256 | sha256);
  def evidence_pair(url_filter):
    ((.[0] == null and .[1] == null) or
      ((.[0] | url_filter) and (.[1] | sha256)));
  def runtime:
    . as $runtime |
    type == "object" and
    (keys == [
      "canary_attestation_sha256",
      "canary_attestation_url",
      "integration_attestation_sha256",
      "integration_attestation_url",
      "manifest_sha256",
      "manifest_url",
      "runtime_id",
      "support",
      "upstream_version"
    ]) and
    (.runtime_id | runtime_id) and
    (.manifest_url | manifest_url($runtime.runtime_id)) and
    (.manifest_sha256 | sha256) and
    (.upstream_version | version) and
    (.runtime_id | capture("^firecracker-(?<version>v[0-9]+[.][0-9]+[.][0-9]+)-yeet-v[1-9][0-9]*$").version) == .upstream_version and
    (.support == "supported" or .support == "deprecated" or .support == "eol" or .support == "revoked") and
    ([.integration_attestation_url, .integration_attestation_sha256] |
      evidence_pair(integration_url($runtime.runtime_id))) and
    ([.canary_attestation_url, .canary_attestation_sha256] |
      evidence_pair(canary_url($runtime.runtime_id)));
  def revocation:
    type == "object" and
    (keys == ["manifest_sha256", "reason", "recorded_at", "runtime_id"]) and
    (.runtime_id | runtime_id) and
    (.manifest_sha256 | sha256) and
    (.reason | type == "string" and length > 0) and
    (.recorded_at | type == "string" and fromdateiso8601);
  def matches($runtime; $pointer):
    $runtime.runtime_id == $pointer.runtime_id and
    $runtime.manifest_sha256 == $pointer.manifest_sha256;
  def channel_resolves($architecture; $channel; $required_evidence):
    if $channel == null then true
    else
      ($channel | pointer) and
      ([$architecture.runtimes[] | select(matches(.; $channel))] | length == 1) and
      (([$architecture.runtimes[] | select(matches(.; $channel))][0]) as $runtime |
        $runtime.support != "revoked" and
        $runtime.integration_attestation_url != null and
        $runtime.integration_attestation_sha256 != null and
        (if $required_evidence == "stable"
         then $runtime.canary_attestation_url != null and $runtime.canary_attestation_sha256 != null
         else true
         end))
    end;
  . as $catalog |
  .schema_version == 1 and
  (keys == ["architectures", "revocations", "schema_version"]) and
  (.architectures | type == "object" and keys == ["amd64"]) and
  all(.architectures[];
    type == "object" and
    (keys == ["channels", "runtimes"]) and
    (.runtimes | type == "array") and
    all(.runtimes[]; runtime) and
    (.channels | type == "object" and keys == ["candidate", "stable"]) and
    (.channels.candidate == null or (.channels.candidate | pointer)) and
    (.channels.stable == null or (.channels.stable | pointer))) and
  (.revocations | type == "array") and
  all(.revocations[]; revocation) and
  all(.architectures[];
    (.runtimes | group_by(.runtime_id) | all(.[]; length == 1))) and
  (.revocations | group_by(.runtime_id) | all(.[]; length == 1)) and
  all(.architectures[];
    . as $architecture |
    channel_resolves($architecture; $architecture.channels.candidate; "candidate") and
    channel_resolves($architecture; $architecture.channels.stable; "stable") and
    (if ($architecture.channels.stable != null and
         $architecture.channels.candidate != null and
         $architecture.channels.stable.runtime_id == $architecture.channels.candidate.runtime_id)
     then $architecture.channels.stable.manifest_sha256 == $architecture.channels.candidate.manifest_sha256
     else true
     end)) and
  all(.revocations[];
    . as $revocation |
    ([$catalog.architectures[].runtimes[] |
      select(matches(.; $revocation) and .support == "revoked")] | length == 1) and
    all($catalog.architectures[].channels[];
      . == null or .runtime_id != $revocation.runtime_id)) and
  all(.architectures[].runtimes[];
    . as $runtime |
    if $runtime.support == "revoked"
    then ([$catalog.revocations[] | select(matches($runtime; .))] | length == 1)
    else true
    end)
' "$catalog" >/dev/null; then
	echo "invalid Firecracker runtime catalog: $catalog" >&2
	exit 1
fi
