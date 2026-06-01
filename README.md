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
