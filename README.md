# yeet-vm-images

Yeet VM image bundles published as GitHub release assets.

The current experimental Ubuntu payload is:

```text
vm://ubuntu/26.04
```

The current bundle version is `ubuntu-26.04-amd64-v1`. It is built from
Canonical's official Ubuntu 26.04 cloud image and boots the Ubuntu
`7.0.0-15-generic` kernel under Firecracker using an initrd.

Release assets:

- `manifest.json`
- `vmlinux`
- `initrd.img`
- `rootfs.ext4.zst`
- `firecracker`
- `checksums.txt`

The manifest includes asset checksums and source provenance. Build the bundle on
a Linux host with:

```bash
scripts/build-ubuntu-26.04.sh dist/ubuntu-26.04-amd64-v1
```

## Publish a New Bundle

Use the **Build Ubuntu 26.04 VM image** GitHub Actions workflow from the Actions
tab. It is manually dispatched and runs on a GitHub-hosted Linux runner.

Inputs:

- `version`: release and image version, for example `ubuntu-26.04-amd64-v2`
- `ubuntu_cloud_base_url`: Ubuntu cloud image directory URL
- `ubuntu_cloud_image`: Ubuntu cloud image tarball name
- `firecracker_version`: Firecracker release version
- `zstd_level`: compression level for `rootfs.ext4.zst`
- `overwrite_release`: delete an existing release/tag with the same version
  before publishing

The workflow builds the bundle, validates `checksums.txt`, prints the manifest,
and publishes the release assets.
