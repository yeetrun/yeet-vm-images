# yeet-vm-images

Yeet VM image bundles published as GitHub release assets.

The current experimental Ubuntu payload is:

```text
vm://ubuntu/26.04
```

The current fast bundle version is `ubuntu-26.04-amd64-v2`. It is built from
Canonical's official Ubuntu 26.04 cloud image and boots a yeet-managed Linux
kernel under Firecracker direct kernel boot without an initrd.

Release assets:

- `manifest.json`
- `vmlinux`
- `rootfs.ext4.zst`
- `firecracker`
- `kernel.config`
- `checksums.txt`

The manifest includes asset checksums and source provenance. The fast image
profile intentionally does not support snaps, and guest apt upgrades do not
manage the boot kernel, bootloader, or initramfs.

Build the full bundle on a Linux host with:

```bash
scripts/build-linux-kernel.sh dist/kernel-linux-7.0
sudo YEET_VM_KERNEL_PATH="$PWD/dist/kernel-linux-7.0/vmlinux" \
  YEET_VM_KERNEL_VERSION=linux-7.0-yeet \
  scripts/build-ubuntu-26.04.sh dist/ubuntu-26.04-amd64-v2
```

## Publish a New Bundle

Use the **Build Ubuntu 26.04 VM image** GitHub Actions workflow from the Actions
tab. It is manually dispatched and runs on a GitHub-hosted Linux runner. The
workflow builds the managed kernel, customizes the Ubuntu rootfs, verifies the
bundle, and publishes the release assets.

Inputs:

- `version`: release and image version, for example `ubuntu-26.04-amd64-v2`
- `ubuntu_cloud_base_url`: Ubuntu cloud image directory URL
- `ubuntu_cloud_image`: Ubuntu cloud image tarball name
- `firecracker_version`: Firecracker release version
- `kernel_version`: Linux kernel version to build
- `kernel_source_url`: Linux kernel source tarball URL
- `kernel_source_sha256`: Linux kernel source tarball SHA-256
- `kernel_config_url`: Firecracker guest kernel config URL used as the build
  baseline
- `zstd_level`: compression level for `rootfs.ext4.zst`
- `overwrite_release`: delete an existing release/tag with the same version
  before publishing

The workflow validates `checksums.txt`, confirms the fast image has no
`initrd.img`, checks the required kernel config values, prints the manifest, and
publishes the release assets.

To reproduce the old v1-style image for debugging, use:

```bash
YEET_VM_IMAGE_PROFILE=stock \
  YEET_VM_IMAGE_VERSION=ubuntu-26.04-amd64-v1 \
  scripts/build-ubuntu-26.04.sh dist/ubuntu-26.04-amd64-v1
```
