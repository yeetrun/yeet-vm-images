#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
synthesizer="$repo_root/scripts/synthesize-firecracker-runtime-test-guest.sh"
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "Firecracker runtime test-guest synthesis test failed: $*" >&2; exit 1; }
file_mode() {
	if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

[ -x "$synthesizer" ] || fail "missing executable runtime test-guest synthesizer"

guest="$tmp_dir/guest"
kernel="$tmp_dir/kernel"
runtime="$tmp_dir/runtime"
mkdir "$guest" "$kernel" "$runtime"
printf 'component rootfs\n' >"$guest/rootfs.ext4.zst"
printf 'component kernel\n' >"$kernel/vmlinux"
printf 'component config\n' >"$kernel/kernel.config"
printf '#!/usr/bin/env bash\nprintf "Firecracker v1.16.1\\n"\n' >"$runtime/firecracker"
printf '#!/usr/bin/env bash\nprintf "Jailer v1.16.1\\n"\n' >"$runtime/jailer"
chmod 0755 "$runtime/firecracker" "$runtime/jailer"

rootfs_sha="$(sha256sum "$guest/rootfs.ext4.zst" | awk '{print $1}')"
kernel_sha="$(sha256sum "$kernel/vmlinux" | awk '{print $1}')"
config_sha="$(sha256sum "$kernel/kernel.config" | awk '{print $1}')"
firecracker_sha="$(sha256sum "$runtime/firecracker" | awk '{print $1}')"
jailer_sha="$(sha256sum "$runtime/jailer" | awk '{print $1}')"

jq -n --arg rootfs "$rootfs_sha" '{
  schema_version:1,guest_base_id:"guest-ubuntu-26.04-amd64-v2",os:"ubuntu",os_version:"26.04",architecture:"amd64",
  rootfs:{url:"https://github.com/yeetrun/yeet-vm-images/releases/download/guest-ubuntu-26.04-amd64-v2/rootfs.ext4.zst",sha256:$rootfs,uncompressed_bytes:2383413248},
  default_kernel_channel:"stable",provenance:{source_commit:"76543210fedcba9876543210fedcba9876543210",workflow_run_url:"https://github.com/yeetrun/yeet-vm-images/actions/runs/123456790"}
}' >"$guest/guest-manifest.json"
jq -n --arg kernel "$kernel_sha" --arg config "$config_sha" '{
  schema_version:1,kernel_id:"kernel-linux-7.1.4-yeet-v4",upstream_version:"7.1.4",packaging_revision:4,architecture:"amd64",
  vmlinux:{url:"https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.4-yeet-v4/vmlinux",sha256:$kernel},
  config:{url:"https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.4-yeet-v4/kernel.config",sha256:$config},
  guest_packages:{catalog_url:"https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-packages/catalog.json",selector_schema_version:2,release_id:"kernel-linux-7.1.4-yeet-v4"},
  provenance:{source_commit:"76543210fedcba9876543210fedcba9876543210",workflow_run_url:"https://github.com/yeetrun/yeet-vm-images/actions/runs/123456791"}
}' >"$kernel/kernel-manifest.json"
jq -n --arg firecracker "$firecracker_sha" --arg jailer "$jailer_sha" '{
  schema_version:1,runtime_id:"firecracker-v1.16.1-yeet-v1",architecture:"amd64",
  upstream:{repository:"firecracker-microvm/firecracker",version:"v1.16.1",tag:"v1.16.1",commit:"76543210fedcba9876543210fedcba9876543210",archive_url:"https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.1/firecracker-v1.16.1-x86_64.tgz",archive_sha256:("a"*64),checksum_url:"https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.1/firecracker-v1.16.1-x86_64.tgz.sha256.txt",tag_signature:{status:"signed",fingerprint:("A"*40)}},
  components:{firecracker:{path:"firecracker",sha256:$firecracker,version_output:"Firecracker v1.16.1"},jailer:{path:"jailer",sha256:$jailer,version_output:"Jailer v1.16.1"}},
  classification:{production_release:true,default_seccomp:true},support:{state:"supported",policy_url:"https://github.com/firecracker-microvm/firecracker/blob/main/docs/RELEASE_POLICY.md"},
  provenance:{repository:"yeetrun/yeet-vm-images",commit:"76543210fedcba9876543210fedcba9876543210",workflow_run:"123456792"}
}' >"$runtime/runtime-manifest.json"

out="$tmp_dir/out"
"$synthesizer" --guest-dir "$guest" --kernel-dir "$kernel" --runtime-dir "$runtime" --out-dir "$out"
expected=$'firecracker\njailer\nmanifest.json\nrootfs.ext4.zst\nvmlinux'
actual="$(cd "$out" && printf '%s\n' * | LC_ALL=C sort)"
[ "$actual" = "$expected" ] || fail "synthesized asset set differs"
jq -e --arg rootfs "$rootfs_sha" --arg kernel "$kernel_sha" --arg firecracker "$firecracker_sha" --arg jailer "$jailer_sha" '
  .name == "yeet-ubuntu-26.04" and
  .version == "guest-ubuntu-26.04-amd64-v2--kernel-linux-7.1.4-yeet-v4--firecracker-v1.16.1-yeet-v1" and
  .architecture == "amd64" and .image_profile == "ubuntu-26.04" and
  .distro == "ubuntu" and .distro_version == "26.04" and .default_user == "ubuntu" and
  .kernel_policy == "yeet-managed" and .guest_init == "/usr/local/lib/yeet-vm/yeet-init" and
  .metadata_driver == "ubuntu" and .snap_support == false and
  .kernel == "vmlinux" and .rootfs == "rootfs.ext4.zst" and
  .firecracker == "firecracker" and .jailer == "jailer" and .rootfs_size == 2383413248 and
  .kernel_version == "kernel-linux-7.1.4-yeet-v4" and .upstream_kernel_version == "7.1.4" and
  .checksums == {"rootfs.ext4.zst":$rootfs,vmlinux:$kernel,firecracker:$firecracker,jailer:$jailer}
' "$out/manifest.json" >/dev/null || fail "synthesized manifest differs"
[ "$(file_mode "$out/firecracker")" = 755 ] || fail "Firecracker mode differs"
[ "$(file_mode "$out/jailer")" = 755 ] || fail "jailer mode differs"

if "$synthesizer" --guest-dir "$guest" --kernel-dir "$kernel" --runtime-dir "$runtime" --out-dir "$out" >/dev/null 2>&1; then
  fail "synthesizer overwrote an existing output"
fi
printf 'tampered\n' >>"$guest/rootfs.ext4.zst"
if "$synthesizer" --guest-dir "$guest" --kernel-dir "$kernel" --runtime-dir "$runtime" --out-dir "$tmp_dir/tampered" >/dev/null 2>&1; then
  fail "synthesizer accepted a tampered component"
fi

echo "Firecracker runtime component test guest synthesis verified"
