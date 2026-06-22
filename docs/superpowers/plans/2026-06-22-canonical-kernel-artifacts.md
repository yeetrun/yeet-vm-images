# Canonical Kernel Artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build each yeet-managed Linux kernel once as a canonical release, then make Ubuntu, NixOS, apt packages, and Nix packages consume that release instead of sourcing kernel packages from an Ubuntu image release.

**Architecture:** Add a canonical kernel release layer with immutable tags such as `kernel-linux-7.1.1-yeet-v1`. The latest-kernel orchestrator resolves or publishes that kernel release, package publishing points metadata at the kernel release, and OS image workflows download verified kernel assets when `kernel_release` is supplied while keeping local kernel builds as the manual fallback.

**Tech Stack:** GitHub Actions reusable workflows, Bash, `gh`, `curl`, `jq`, `sha256sum`, existing yeet VM image build scripts.

---

## File Structure

- Create `.github/workflows/build-kernel.yml`
  - Reusable and manual workflow that builds `vmlinux`, `kernel.config`, `kernel-manifest.json`, and `kernel-checksums.txt`, then publishes an immutable kernel release.
- Modify `.github/workflows/sync-latest-stable-kernel.yml`
  - Resolve the canonical kernel release, build it when missing or stale, pass it to package and OS workflows, and remove package coupling to Ubuntu image releases.
- Modify `.github/workflows/publish-kernel-packages.yml`
  - Replace `image_release` input with `kernel_release`, download canonical kernel assets, and write `kernel-packages/metadata.nix` URLs pointing at `kernel-linux-<upstream>-yeet-v<N>` releases.
- Modify `.github/workflows/build-ubuntu-26.04.yml`
  - Add optional `kernel_release` input and use downloaded canonical assets when supplied.
- Modify `.github/workflows/build-nixos-26.05.yml`
  - Add optional `kernel_release` input and use downloaded canonical assets when supplied.
- Create `scripts/resolve-kernel-release.sh`
  - Parse existing tags and return current and next canonical release names for an upstream kernel.
- Create `scripts/download-kernel-release.sh`
  - Download and verify `kernel-manifest.json`, `vmlinux`, and `kernel.config` from a canonical kernel release.
- Create `scripts/test-download-kernel-release.sh`
  - Test canonical kernel release download and manifest/checksum validation with a mocked `curl`.
- Create `scripts/publish-kernel-release-assets.sh`
  - Publish canonical kernel release assets with draft cleanup semantics matching image release publishing.
- Modify `scripts/test-latest-kernel-automation.sh`
  - Add resolver tests for canonical kernel release naming.
- Modify `scripts/test-publish-release-assets.sh`
  - Add tests for kernel release asset publishing and cleanup.
- Modify `scripts/test-kernel-packages.sh`
  - Add package provenance checks for canonical kernel release metadata.
- Create `scripts/test-kernel-release-workflows.sh`
  - Static workflow and domain guard tests for the new artifact boundary.
- Create `scripts/testdata/kernel-release-tags.txt`
  - Fixture for resolver tests.
- Modify `packages/kernel/deb/DEBIAN/control.in`
  - Replace the invalid `yeet[.]run` maintainer identity with `yeetrun.com`.
- Modify `README.md`
  - Document canonical kernel releases, manual fallback behavior, and package provenance.

---

### Task 1: Kernel Release Resolver

**Files:**
- Create: `scripts/resolve-kernel-release.sh`
- Create: `scripts/testdata/kernel-release-tags.txt`
- Modify: `scripts/test-latest-kernel-automation.sh`

- [ ] **Step 1: Add the resolver fixture**

Create `scripts/testdata/kernel-release-tags.txt`:

```text
ubuntu-26.04-amd64-v16
ubuntu-26.04-amd64-kernel-7.1.1-v18
nixos-26.05-amd64-kernel-7.1.1-v6
kernel-linux-7.0-yeet-v1
kernel-linux-7.1.1-yeet-v1
kernel-linux-7.1.1-yeet-v2
kernel-linux-7.1.2-yeet-v1
kernel-linux-7.1.2-yeet-v9-extra
not-a-kernel-release
```

- [ ] **Step 2: Write the failing resolver tests**

Append this block to `scripts/test-latest-kernel-automation.sh` after the existing `next-image-version.sh` assertions:

```bash
kernel_release="$("$repo_root/scripts/resolve-kernel-release.sh" 7.1.1 "$testdata_dir/kernel-release-tags.txt")"
jq -e '
  .upstream_kernel_version == "7.1.1" and
  .kernel_version == "linux-7.1.1-yeet" and
  .current_revision == 2 and
  .current_release == "kernel-linux-7.1.1-yeet-v2" and
  .next_revision == 3 and
  .next_release == "kernel-linux-7.1.1-yeet-v3"
' <<<"$kernel_release" >/dev/null

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
```

- [ ] **Step 3: Run the resolver tests and confirm failure**

Run:

```bash
bash scripts/test-latest-kernel-automation.sh
```

Expected: FAIL because `scripts/resolve-kernel-release.sh` does not exist.

- [ ] **Step 4: Implement `scripts/resolve-kernel-release.sh`**

Create `scripts/resolve-kernel-release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 <kernel-version> [tags-file]" >&2
	exit 2
}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	usage
fi

kernel_version="$1"
tags_file="${2:-}"

for cmd in awk jq; do
	require "$cmd"
done
if [ -z "$tags_file" ]; then
	require gh
fi

if [[ ! "$kernel_version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)*$ ]]; then
	echo "invalid kernel version: $kernel_version" >&2
	exit 1
fi
if [ -n "$tags_file" ] && [ ! -r "$tags_file" ]; then
	echo "tags file is not readable: $tags_file" >&2
	exit 1
fi

release_prefix="kernel-linux-${kernel_version}-yeet-v"

resolve_from_tags() {
	awk -v prefix="$release_prefix" '
	  BEGIN { max = 0 }
	  {
	    tag = $0
	    if (index(tag, prefix) == 1) {
	      revision = substr(tag, length(prefix) + 1)
	      if (revision ~ /^[0-9]+$/ && revision + 0 > max) {
	        max = revision + 0
	      }
	    }
	  }
	  END { print max }
	'
}

if [ -n "$tags_file" ]; then
	current_revision="$(resolve_from_tags <"$tags_file")"
else
	current_revision="$(
		gh release list --limit 200 --json tagName --jq '.[].tagName' |
			resolve_from_tags
	)"
fi

current_release=""
if [ "$current_revision" -gt 0 ]; then
	current_release="${release_prefix}${current_revision}"
fi
next_revision="$((current_revision + 1))"
next_release="${release_prefix}${next_revision}"

jq -n \
	--arg upstream_kernel_version "$kernel_version" \
	--arg kernel_version "linux-${kernel_version}-yeet" \
	--arg current_release "$current_release" \
	--arg next_release "$next_release" \
	--argjson current_revision "$current_revision" \
	--argjson next_revision "$next_revision" \
	'{
	  upstream_kernel_version: $upstream_kernel_version,
	  kernel_version: $kernel_version,
	  current_revision: $current_revision,
	  current_release: $current_release,
	  next_revision: $next_revision,
	  next_release: $next_release
	}'
```

Make it executable:

```bash
chmod +x scripts/resolve-kernel-release.sh
```

- [ ] **Step 5: Run the resolver tests and confirm pass**

Run:

```bash
bash scripts/test-latest-kernel-automation.sh
```

Expected: PASS with no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/resolve-kernel-release.sh scripts/testdata/kernel-release-tags.txt scripts/test-latest-kernel-automation.sh
git commit -m "kernel: add canonical release resolver"
```

---

### Task 2: Kernel Release Publisher

**Files:**
- Create: `scripts/publish-kernel-release-assets.sh`
- Create: `.github/workflows/build-kernel.yml`
- Modify: `scripts/test-publish-release-assets.sh`

- [ ] **Step 1: Add failing tests for the kernel release publisher**

In `scripts/test-publish-release-assets.sh`, create a second output directory after the existing `out_dir` setup:

```bash
kernel_out_dir="$tmp_dir/kernel-out"
mkdir -p "$kernel_out_dir"
for asset in vmlinux kernel.config kernel-manifest.json kernel-checksums.txt; do
	printf '%s\n' "$asset payload" >"$kernel_out_dir/$asset"
done
```

Append this success case after the existing image release success assertion:

```bash
YEET_FAKE_GH_LOG="$tmp_dir/kernel-success.log"
export YEET_FAKE_GH_LOG
PATH="$bin_dir:$PATH" "$repo_root/scripts/publish-kernel-release-assets.sh" \
	kernel-linux-7.1.1-yeet-v1 \
	kernel-linux-7.1.1-yeet-v1 \
	abc123 \
	"$out_dir/release-notes.md" \
	"$kernel_out_dir"

assert_log "create kernel-linux-7.1.1-yeet-v1 --draft --target abc123 --title kernel-linux-7.1.1-yeet-v1 --notes-file $out_dir/release-notes.md
upload kernel-linux-7.1.1-yeet-v1 vmlinux
upload kernel-linux-7.1.1-yeet-v1 kernel.config
upload kernel-linux-7.1.1-yeet-v1 kernel-manifest.json
upload kernel-linux-7.1.1-yeet-v1 kernel-checksums.txt
edit kernel-linux-7.1.1-yeet-v1 --draft=false"
```

Append this failure case after the existing image release failure assertion:

```bash
YEET_FAKE_GH_LOG="$tmp_dir/kernel-failure.log"
YEET_FAKE_GH_FAIL_UPLOAD="kernel.config"
export YEET_FAKE_GH_LOG YEET_FAKE_GH_FAIL_UPLOAD
if PATH="$bin_dir:$PATH" "$repo_root/scripts/publish-kernel-release-assets.sh" \
	kernel-linux-7.1.1-yeet-v1 \
	kernel-linux-7.1.1-yeet-v1 \
	abc123 \
	"$out_dir/release-notes.md" \
	"$kernel_out_dir"; then
	echo "kernel publish helper succeeded despite a failed kernel.config upload" >&2
	exit 1
fi

assert_log "create kernel-linux-7.1.1-yeet-v1 --draft --target abc123 --title kernel-linux-7.1.1-yeet-v1 --notes-file $out_dir/release-notes.md
upload kernel-linux-7.1.1-yeet-v1 vmlinux
upload kernel-linux-7.1.1-yeet-v1 kernel.config
delete kernel-linux-7.1.1-yeet-v1 --yes"
unset YEET_FAKE_GH_FAIL_UPLOAD
```

- [ ] **Step 2: Run the publisher test and confirm failure**

Run:

```bash
bash scripts/test-publish-release-assets.sh
```

Expected: FAIL because `scripts/publish-kernel-release-assets.sh` does not exist.

- [ ] **Step 3: Implement `scripts/publish-kernel-release-assets.sh`**

Create `scripts/publish-kernel-release-assets.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
	echo "usage: $0 <tag> <title> <target> <notes-file> <out-dir>" >&2
	exit 2
fi

tag="$1"
title="$2"
target="$3"
notes_file="$4"
out_dir="$5"
upload_timeout="${YEET_RELEASE_UPLOAD_TIMEOUT:-30m}"
assets=(
	vmlinux
	kernel.config
	kernel-manifest.json
	kernel-checksums.txt
)
release_created=0
release_published=0

file_size() {
	local path="$1"
	if stat -c %s "$path" >/dev/null 2>&1; then
		stat -c %s "$path"
	else
		stat -f %z "$path"
	fi
}

cleanup_draft() {
	if [ "$release_created" -eq 1 ] && [ "$release_published" -eq 0 ]; then
		echo "Deleting incomplete draft release $tag" >&2
		gh release delete "$tag" --yes >/dev/null 2>&1 || true
	fi
}

on_error() {
	local status="$?"
	cleanup_draft
	exit "$status"
}
trap on_error ERR INT TERM

for asset in "${assets[@]}"; do
	path="$out_dir/$asset"
	if [ ! -s "$path" ]; then
		echo "release asset is missing or empty: $path" >&2
		exit 1
	fi
done

gh release create "$tag" \
	--draft \
	--target "$target" \
	--title "$title" \
	--notes-file "$notes_file"
release_created=1

for asset in "${assets[@]}"; do
	path="$out_dir/$asset"
	size="$(file_size "$path")"
	echo "Uploading $asset ($size bytes) to $tag"
	if command -v timeout >/dev/null 2>&1; then
		timeout "$upload_timeout" gh release upload "$tag" "$path" --clobber
	else
		gh release upload "$tag" "$path" --clobber
	fi
	echo "Uploaded $asset"
done

gh release edit "$tag" --draft=false
release_published=1
trap - ERR INT TERM
```

Make it executable:

```bash
chmod +x scripts/publish-kernel-release-assets.sh
```

- [ ] **Step 4: Add `.github/workflows/build-kernel.yml`**

Create `.github/workflows/build-kernel.yml` with these inputs and job behavior:

```yaml
name: Build yeet kernel

on:
  workflow_call:
    inputs:
      kernel_release:
        description: Canonical kernel release tag to publish, for example kernel-linux-7.1.1-yeet-v1.
        required: true
        type: string
      kernel_version:
        description: Upstream Linux kernel version to build.
        required: true
        type: string
      kernel_source_url:
        description: Linux kernel source tarball URL.
        required: true
        type: string
      kernel_source_sha256:
        description: Linux kernel source tarball SHA-256.
        required: true
        type: string
      kernel_config_url:
        description: Firecracker guest kernel config URL.
        required: true
        type: string
      overwrite_release:
        description: Delete an existing release/tag with the same version before publishing.
        required: false
        type: boolean
        default: false
  workflow_dispatch:
    inputs:
      kernel_release:
        description: Canonical kernel release tag to publish, for example kernel-linux-7.1.1-yeet-v1.
        required: true
      kernel_version:
        description: Upstream Linux kernel version to build.
        required: true
      kernel_source_url:
        description: Linux kernel source tarball URL.
        required: true
      kernel_source_sha256:
        description: Linux kernel source tarball SHA-256.
        required: true
      kernel_config_url:
        description: Firecracker guest kernel config URL.
        required: true
      overwrite_release:
        description: Delete an existing release/tag with the same version before publishing.
        required: true
        type: boolean
        default: false

permissions:
  contents: write

jobs:
  build:
    name: Build and publish canonical kernel
    runs-on: ubuntu-24.04
    timeout-minutes: 90
    env:
      KERNEL_RELEASE: ${{ inputs.kernel_release }}
      KERNEL_VERSION: ${{ inputs.kernel_version }}
      KERNEL_SOURCE_URL: ${{ inputs.kernel_source_url }}
      KERNEL_SOURCE_SHA256: ${{ inputs.kernel_source_sha256 }}
      KERNEL_CONFIG_URL: ${{ inputs.kernel_config_url }}
      KERNEL_OUT_DIR: dist/${{ inputs.kernel_release }}
      YEET_KERNEL_VERSION: ${{ inputs.kernel_version }}
      YEET_KERNEL_SOURCE_URL: ${{ inputs.kernel_source_url }}
      YEET_KERNEL_SOURCE_SHA256: ${{ inputs.kernel_source_sha256 }}
      YEET_KERNEL_CONFIG_URL: ${{ inputs.kernel_config_url }}
      YEET_KERNEL_WORK_DIR: ${{ github.workspace }}/.kernel-build-work
      GH_TOKEN: ${{ github.token }}
```

The job steps should:

```yaml
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            bc \
            bison \
            build-essential \
            curl \
            dwarves \
            file \
            flex \
            jq \
            libelf-dev \
            libssl-dev \
            ncurses-bin \
            xz-utils

      - name: Build kernel
        run: |
          scripts/build-linux-kernel.sh "$KERNEL_OUT_DIR"

      - name: Write kernel manifest
        run: |
          set -euo pipefail
          vmlinux_sha="$(sha256sum "$KERNEL_OUT_DIR/vmlinux" | awk '{ print $1 }')"
          kernel_config_sha="$(sha256sum "$KERNEL_OUT_DIR/kernel.config" | awk '{ print $1 }')"
          sha256sum "$KERNEL_OUT_DIR/vmlinux" "$KERNEL_OUT_DIR/kernel.config" >"$KERNEL_OUT_DIR/kernel-checksums.txt"
          jq -n \
            --arg release "$KERNEL_RELEASE" \
            --arg upstream_kernel_version "$KERNEL_VERSION" \
            --arg kernel_version "linux-${KERNEL_VERSION}-yeet" \
            --arg kernel_source_url "$KERNEL_SOURCE_URL" \
            --arg kernel_source_sha256 "$KERNEL_SOURCE_SHA256" \
            --arg kernel_config_url "$KERNEL_CONFIG_URL" \
            --arg localversion "-yeet" \
            --arg repository "$GITHUB_REPOSITORY" \
            --arg commit "$GITHUB_SHA" \
            --arg vmlinux_sha "$vmlinux_sha" \
            --arg kernel_config_sha "$kernel_config_sha" \
            '{
              schema_version: 1,
              release: $release,
              upstream_kernel_version: $upstream_kernel_version,
              kernel_version: $kernel_version,
              kernel_source_url: $kernel_source_url,
              kernel_source_sha256: $kernel_source_sha256,
              kernel_config_url: $kernel_config_url,
              localversion: $localversion,
              repository: $repository,
              commit: $commit,
              checksums: {
                vmlinux: $vmlinux_sha,
                "kernel.config": $kernel_config_sha
              }
            }' >"$KERNEL_OUT_DIR/kernel-manifest.json"

      - name: Verify kernel assets
        run: |
          set -euo pipefail
          for asset in vmlinux kernel.config kernel-manifest.json kernel-checksums.txt; do
            test -s "$KERNEL_OUT_DIR/$asset"
          done
          (cd "$KERNEL_OUT_DIR" && sha256sum -c kernel-checksums.txt)
          jq -e '
            .schema_version == 1 and
            .release == env.KERNEL_RELEASE and
            .upstream_kernel_version == env.KERNEL_VERSION and
            .kernel_version == ("linux-" + env.KERNEL_VERSION + "-yeet") and
            .kernel_source_url == env.KERNEL_SOURCE_URL and
            .kernel_source_sha256 == env.KERNEL_SOURCE_SHA256 and
            .kernel_config_url == env.KERNEL_CONFIG_URL and
            .localversion == "-yeet" and
            (.checksums.vmlinux | test("^[0-9a-f]{64}$")) and
            (.checksums["kernel.config"] | test("^[0-9a-f]{64}$"))
          ' "$KERNEL_OUT_DIR/kernel-manifest.json"

      - name: Check release target
        run: |
          set -euo pipefail
          overwrite="${{ inputs.overwrite_release }}"
          release_exists=0
          tag_exists=0
          if gh release view "$KERNEL_RELEASE" >/dev/null 2>&1; then
            release_exists=1
          fi
          if git ls-remote --exit-code --tags origin "refs/tags/$KERNEL_RELEASE" >/dev/null 2>&1; then
            tag_exists=1
          fi
          if [ "$release_exists" -eq 0 ] && [ "$tag_exists" -eq 0 ]; then
            exit 0
          fi
          if [ "$overwrite" != "true" ]; then
            echo "Release or tag $KERNEL_RELEASE already exists. Re-run with overwrite_release=true to replace it." >&2
            exit 1
          fi
          if [ "$release_exists" -eq 1 ]; then
            gh release delete "$KERNEL_RELEASE" --cleanup-tag --yes
          elif [ "$tag_exists" -eq 1 ]; then
            git push origin ":refs/tags/$KERNEL_RELEASE"
          fi

      - name: Prepare release notes
        run: |
          cat >"$KERNEL_OUT_DIR/release-notes.md" <<EOF
          Canonical yeet Firecracker kernel.

          - Release: \`$KERNEL_RELEASE\`
          - Kernel: \`linux-${KERNEL_VERSION}-yeet\`
          - Source: <$KERNEL_SOURCE_URL>
          - Config: <$KERNEL_CONFIG_URL>

          See \`kernel-manifest.json\` for checksums and provenance.
          EOF

      - name: Publish release
        run: |
          scripts/publish-kernel-release-assets.sh \
            "$KERNEL_RELEASE" \
            "$KERNEL_RELEASE" \
            "$GITHUB_SHA" \
            "$KERNEL_OUT_DIR/release-notes.md" \
            "$KERNEL_OUT_DIR"
```

- [ ] **Step 5: Run publisher tests and YAML grep sanity checks**

Run:

```bash
bash scripts/test-publish-release-assets.sh
grep -q 'kernel-manifest.json' .github/workflows/build-kernel.yml
grep -q 'scripts/publish-kernel-release-assets.sh' .github/workflows/build-kernel.yml
```

Expected: PASS with no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/publish-kernel-release-assets.sh scripts/test-publish-release-assets.sh .github/workflows/build-kernel.yml
git commit -m "kernel: publish canonical kernel releases"
```

---

### Task 3: Kernel Release Download Helper and OS Workflow Inputs

**Files:**
- Create: `scripts/download-kernel-release.sh`
- Create: `scripts/test-download-kernel-release.sh`
- Modify: `.github/workflows/build-ubuntu-26.04.yml`
- Modify: `.github/workflows/build-nixos-26.05.yml`

- [ ] **Step 1: Write the failing download-helper test**

Create `scripts/test-download-kernel-release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

fake_bin="$tmp_dir/bin"
remote_dir="$tmp_dir/remote"
out_dir="$tmp_dir/out"
mkdir -p "$fake_bin" "$remote_dir" "$out_dir"

printf 'kernel payload\n' >"$remote_dir/vmlinux"
printf 'config payload\n' >"$remote_dir/kernel.config"
vmlinux_sha="$(sha256sum "$remote_dir/vmlinux" | awk '{ print $1 }')"
kernel_config_sha="$(sha256sum "$remote_dir/kernel.config" | awk '{ print $1 }')"
jq -n \
	--arg release "kernel-linux-7.1.1-yeet-v2" \
	--arg upstream_kernel_version "7.1.1" \
	--arg kernel_version "linux-7.1.1-yeet" \
	--arg kernel_source_url "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz" \
	--arg kernel_source_sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
	--arg kernel_config_url "https://example.invalid/kernel.config" \
	--arg vmlinux_sha "$vmlinux_sha" \
	--arg kernel_config_sha "$kernel_config_sha" \
	'{
	  schema_version: 1,
	  release: $release,
	  upstream_kernel_version: $upstream_kernel_version,
	  kernel_version: $kernel_version,
	  kernel_source_url: $kernel_source_url,
	  kernel_source_sha256: $kernel_source_sha256,
	  kernel_config_url: $kernel_config_url,
	  localversion: "-yeet",
	  repository: "yeetrun/yeet-vm-images",
	  commit: "abc123",
	  checksums: {
	    vmlinux: $vmlinux_sha,
	    "kernel.config": $kernel_config_sha
	  }
	}' >"$remote_dir/kernel-manifest.json"

cat >"$fake_bin/curl" <<'FAKE_CURL'
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
		--retry)
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

if [ -z "$out" ] || [ -z "$url" ]; then
	echo "fake curl missing output or URL" >&2
	exit 1
fi
asset="${url##*/}"
cp "$YEET_TEST_REMOTE_DIR/$asset" "$out"
FAKE_CURL
chmod +x "$fake_bin/curl"

PATH="$fake_bin:$PATH" \
	GITHUB_REPOSITORY=yeetrun/yeet-vm-images \
	YEET_TEST_REMOTE_DIR="$remote_dir" \
	YEET_KERNEL_VERSION=7.1.1 \
	YEET_KERNEL_SOURCE_URL=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz \
	YEET_KERNEL_SOURCE_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
	YEET_KERNEL_CONFIG_URL=https://example.invalid/kernel.config \
	"$repo_root/scripts/download-kernel-release.sh" kernel-linux-7.1.1-yeet-v2 "$out_dir"

cmp "$remote_dir/vmlinux" "$out_dir/vmlinux"
cmp "$remote_dir/kernel.config" "$out_dir/kernel.config"
test -s "$out_dir/kernel-checksums.txt"

if PATH="$fake_bin:$PATH" \
	GITHUB_REPOSITORY=yeetrun/yeet-vm-images \
	YEET_TEST_REMOTE_DIR="$remote_dir" \
	YEET_KERNEL_VERSION=7.1.2 \
	"$repo_root/scripts/download-kernel-release.sh" kernel-linux-7.1.1-yeet-v2 "$tmp_dir/bad" >/dev/null 2>&1; then
	echo "download helper accepted mismatched kernel version" >&2
	exit 1
fi
```

Make it executable:

```bash
chmod +x scripts/test-download-kernel-release.sh
```

- [ ] **Step 2: Run the download-helper test and confirm failure**

Run:

```bash
bash scripts/test-download-kernel-release.sh
```

Expected: FAIL because `scripts/download-kernel-release.sh` does not exist.

- [ ] **Step 3: Create the download helper**

Create `scripts/download-kernel-release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 <kernel-release> <out-dir>" >&2
	exit 2
}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

if [ "$#" -ne 2 ]; then
	usage
fi

kernel_release="$1"
out_dir="$2"
repo="${GITHUB_REPOSITORY:-yeetrun/yeet-vm-images}"
expected_kernel_version="${YEET_KERNEL_VERSION:-}"
expected_source_url="${YEET_KERNEL_SOURCE_URL:-}"
expected_source_sha256="${YEET_KERNEL_SOURCE_SHA256:-}"
expected_config_url="${YEET_KERNEL_CONFIG_URL:-}"

for cmd in awk curl jq mkdir sha256sum; do
	require "$cmd"
done

if [[ ! "$kernel_release" =~ ^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[0-9]+$ ]]; then
	echo "invalid kernel release: $kernel_release" >&2
	exit 1
fi

mkdir -p "$out_dir"
asset_base="https://github.com/${repo}/releases/download/${kernel_release}"
curl -fsSL --retry 3 -o "$out_dir/kernel-manifest.json" "$asset_base/kernel-manifest.json"
curl -fsSL --retry 3 -o "$out_dir/vmlinux" "$asset_base/vmlinux"
curl -fsSL --retry 3 -o "$out_dir/kernel.config" "$asset_base/kernel.config"

manifest_release="$(jq -r '.release' "$out_dir/kernel-manifest.json")"
if [ "$manifest_release" != "$kernel_release" ]; then
	echo "kernel manifest release mismatch: manifest=$manifest_release requested=$kernel_release" >&2
	exit 1
fi

if [ -n "$expected_kernel_version" ]; then
	manifest_upstream="$(jq -r '.upstream_kernel_version' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_upstream" != "$expected_kernel_version" ]; then
		echo "kernel manifest version mismatch: manifest=$manifest_upstream expected=$expected_kernel_version" >&2
		exit 1
	fi
fi

if [ -n "$expected_source_url" ]; then
	manifest_source_url="$(jq -r '.kernel_source_url' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_source_url" != "$expected_source_url" ]; then
		echo "kernel source URL mismatch: manifest=$manifest_source_url expected=$expected_source_url" >&2
		exit 1
	fi
fi

if [ -n "$expected_source_sha256" ]; then
	manifest_source_sha256="$(jq -r '.kernel_source_sha256' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_source_sha256" != "$expected_source_sha256" ]; then
		echo "kernel source SHA mismatch: manifest=$manifest_source_sha256 expected=$expected_source_sha256" >&2
		exit 1
	fi
fi

if [ -n "$expected_config_url" ]; then
	manifest_config_url="$(jq -r '.kernel_config_url' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_config_url" != "$expected_config_url" ]; then
		echo "kernel config URL mismatch: manifest=$manifest_config_url expected=$expected_config_url" >&2
		exit 1
	fi
fi

check_asset() {
	local asset="$1"
	local want
	local got
	want="$(jq -r --arg asset "$asset" '.checksums[$asset] // empty' "$out_dir/kernel-manifest.json")"
	if [ -z "$want" ]; then
		echo "kernel manifest missing checksum for $asset" >&2
		exit 1
	fi
	got="$(sha256sum "$out_dir/$asset" | awk '{ print $1 }')"
	if [ "$got" != "$want" ]; then
		echo "$asset checksum mismatch: got $got, want $want" >&2
		exit 1
	fi
}

check_asset vmlinux
check_asset kernel.config
sha256sum "$out_dir/vmlinux" "$out_dir/kernel.config" >"$out_dir/kernel-checksums.txt"
```

Make it executable:

```bash
chmod +x scripts/download-kernel-release.sh
```

- [ ] **Step 4: Run the download-helper test and confirm pass**

Run:

```bash
bash scripts/test-download-kernel-release.sh
```

Expected: PASS with no output.

- [ ] **Step 5: Add `kernel_release` inputs to Ubuntu workflow**

In `.github/workflows/build-ubuntu-26.04.yml`, add this input under both `workflow_call.inputs` and `workflow_dispatch.inputs`:

```yaml
      kernel_release:
        description: Canonical kernel release to consume. Empty builds the kernel locally.
        required: false
        type: string
        default: ""
```

For `workflow_dispatch`, omit `type: string` because the current file uses plain string inputs:

```yaml
      kernel_release:
        description: Canonical kernel release to consume. Empty builds the kernel locally.
        required: false
        default: ""
```

Add this env entry:

```yaml
      KERNEL_RELEASE: ${{ inputs.kernel_release }}
```

Replace the `Build yeet-managed kernel` step with:

```yaml
      - name: Prepare yeet-managed kernel
        run: |
          set -euo pipefail
          if [ -n "$KERNEL_RELEASE" ]; then
            scripts/download-kernel-release.sh "$KERNEL_RELEASE" "$KERNEL_OUT_DIR"
          else
            scripts/build-linux-kernel.sh "$KERNEL_OUT_DIR"
          fi
```

- [ ] **Step 6: Add `kernel_release` inputs to NixOS workflow**

In `.github/workflows/build-nixos-26.05.yml`, add the same `kernel_release` inputs and `KERNEL_RELEASE` env entry.

Replace the `Build yeet-managed kernel` step with:

```yaml
      - name: Prepare yeet-managed kernel
        run: |
          set -euo pipefail
          if [ -n "$KERNEL_RELEASE" ]; then
            scripts/download-kernel-release.sh "$KERNEL_RELEASE" "$KERNEL_OUT_DIR"
          else
            scripts/build-linux-kernel.sh "$KERNEL_OUT_DIR"
          fi
```

- [ ] **Step 7: Run syntax and workflow-input checks**

Run:

```bash
bash -n scripts/download-kernel-release.sh
bash -n scripts/test-download-kernel-release.sh
bash scripts/test-download-kernel-release.sh
grep -q 'kernel_release:' .github/workflows/build-ubuntu-26.04.yml
grep -q 'kernel_release:' .github/workflows/build-nixos-26.05.yml
grep -q 'scripts/download-kernel-release.sh "$KERNEL_RELEASE" "$KERNEL_OUT_DIR"' .github/workflows/build-ubuntu-26.04.yml
grep -q 'scripts/download-kernel-release.sh "$KERNEL_RELEASE" "$KERNEL_OUT_DIR"' .github/workflows/build-nixos-26.05.yml
```

Expected: PASS with no output.

- [ ] **Step 8: Commit**

```bash
git add scripts/download-kernel-release.sh scripts/test-download-kernel-release.sh .github/workflows/build-ubuntu-26.04.yml .github/workflows/build-nixos-26.05.yml
git commit -m "images: consume canonical kernel releases"
```

---

### Task 4: Package Publishing From Canonical Kernel Release

**Files:**
- Modify: `.github/workflows/publish-kernel-packages.yml`
- Modify: `scripts/test-kernel-packages.sh`

- [ ] **Step 1: Add failing package provenance assertions**

Append these static checks to `scripts/test-kernel-packages.sh`:

```bash
grep -q 'kernel_release:' "$repo_root/.github/workflows/publish-kernel-packages.yml"
if grep -q 'image_release:' "$repo_root/.github/workflows/publish-kernel-packages.yml"; then
	echo "publish-kernel-packages.yml must not accept image_release" >&2
	exit 1
fi
grep -q 'KERNEL_RELEASE:' "$repo_root/.github/workflows/publish-kernel-packages.yml"
grep -q 'kernel-manifest.json' "$repo_root/.github/workflows/publish-kernel-packages.yml"
grep -q 'releases/download/${KERNEL_RELEASE}' "$repo_root/.github/workflows/publish-kernel-packages.yml"
if grep -q 'ubuntu-26.04-amd64-kernel' "$repo_root/kernel-packages/metadata.nix"; then
	echo "kernel package metadata must not point at Ubuntu image releases" >&2
	exit 1
fi
```

- [ ] **Step 2: Run the package test and confirm failure**

Run:

```bash
bash scripts/test-kernel-packages.sh
```

Expected: FAIL because the workflow still accepts `image_release`.

- [ ] **Step 3: Replace `image_release` with `kernel_release`**

In `.github/workflows/publish-kernel-packages.yml`:

- Replace both input definitions named `image_release` with:

```yaml
      kernel_release:
        description: Immutable canonical kernel release whose vmlinux and kernel.config assets should be packaged.
        required: true
        type: string
```

For `workflow_dispatch`, omit `type: string`:

```yaml
      kernel_release:
        description: Immutable canonical kernel release whose vmlinux and kernel.config assets should be packaged.
        required: true
```

- Replace env `IMAGE_RELEASE` with:

```yaml
      KERNEL_RELEASE: ${{ inputs.kernel_release }}
```

- Rename the download step to `Download canonical kernel assets`.

- Replace the download step body with:

```bash
set -euo pipefail

asset_base="https://github.com/${GITHUB_REPOSITORY}/releases/download/${KERNEL_RELEASE}"
kernel_dir="dist/kernel-package-source"
mkdir -p "$kernel_dir"
curl -fsSL --retry 3 -o "$kernel_dir/kernel-manifest.json" "$asset_base/kernel-manifest.json"
curl -fsSL --retry 3 -o "$kernel_dir/vmlinux" "$asset_base/vmlinux"
curl -fsSL --retry 3 -o "$kernel_dir/kernel.config" "$asset_base/kernel.config"

manifest_release="$(jq -r '.release' "$kernel_dir/kernel-manifest.json")"
if [ "$manifest_release" != "$KERNEL_RELEASE" ]; then
  echo "kernel release mismatch: manifest=$manifest_release requested=$KERNEL_RELEASE" >&2
  exit 1
fi
manifest_kernel="$(jq -r '.upstream_kernel_version' "$kernel_dir/kernel-manifest.json")"
if [ "$manifest_kernel" != "$KERNEL_VERSION" ]; then
  echo "kernel release $KERNEL_RELEASE has kernel $manifest_kernel, want $KERNEL_VERSION" >&2
  exit 1
fi
for asset in vmlinux kernel.config; do
  got="$(sha256sum "$kernel_dir/$asset" | awk '{ print $1 }')"
  want="$(jq -r --arg asset "$asset" '.checksums[$asset] // empty' "$kernel_dir/kernel-manifest.json")"
  if [ -z "$want" ] || [ "$got" != "$want" ]; then
    echo "$asset checksum mismatch: got $got, want ${want:-missing}" >&2
    exit 1
  fi
done
```

- In the metadata generation step, replace the `asset_base` assignment with:

```bash
asset_base="https://github.com/${GITHUB_REPOSITORY}/releases/download/${KERNEL_RELEASE}"
```

- [ ] **Step 4: Run package tests**

Run:

```bash
bash scripts/test-kernel-packages.sh
```

Expected: PASS with no output.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/publish-kernel-packages.yml scripts/test-kernel-packages.sh
git commit -m "packages: source kernels from canonical releases"
```

---

### Task 5: Latest-Kernel Orchestration

**Files:**
- Modify: `.github/workflows/sync-latest-stable-kernel.yml`
- Create: `scripts/test-kernel-release-workflows.sh`

- [ ] **Step 1: Add failing orchestration tests**

Create `scripts/test-kernel-release-workflows.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
	local file="$1"
	local needle="$2"
	if ! grep -Fq "$needle" "$file"; then
		echo "$file does not contain: $needle" >&2
		exit 1
	fi
}

assert_not_contains() {
	local file="$1"
	local needle="$2"
	if grep -Fq "$needle" "$file"; then
		echo "$file still contains: $needle" >&2
		exit 1
	fi
}

assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "kernel_release:"
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "kernel_release_build:"
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "build-kernel:"
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "uses: ./.github/workflows/build-kernel.yml"
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" 'kernel_release: ${{ needs.detect.outputs.kernel_release }}'
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped'"
assert_not_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "package_image_release"
assert_not_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "Kernel package source image release"

assert_contains "$repo_root/.github/workflows/publish-kernel-packages.yml" "kernel_release:"
assert_not_contains "$repo_root/.github/workflows/publish-kernel-packages.yml" "image_release:"
```

Make it executable:

```bash
chmod +x scripts/test-kernel-release-workflows.sh
```

- [ ] **Step 2: Run the orchestration test and confirm failure**

Run:

```bash
bash scripts/test-kernel-release-workflows.sh
```

Expected: FAIL because the sync workflow still uses `package_image_release`.

- [ ] **Step 3: Update detect outputs**

In `.github/workflows/sync-latest-stable-kernel.yml`, replace the `package_image_release` output with:

```yaml
      kernel_current_release: ${{ steps.plan.outputs.kernel_current_release }}
      kernel_release: ${{ steps.plan.outputs.kernel_release }}
      kernel_release_build: ${{ steps.plan.outputs.kernel_release_build }}
```

- [ ] **Step 4: Resolve and compare kernel releases in the plan step**

In the `Plan image builds` shell step:

- Keep image planning unchanged.
- Remove the `package_image_release` calculation.
- Add this logic after image versions are computed:

```bash
          kernel_release_info="$(scripts/resolve-kernel-release.sh "$KERNEL_VERSION")"
          kernel_current_release="$(jq -r '.current_release' <<<"$kernel_release_info")"
          kernel_next_release="$(jq -r '.next_release' <<<"$kernel_release_info")"
          kernel_release="$kernel_next_release"
          kernel_release_build="true"

          if [ -n "$kernel_current_release" ]; then
            asset_base="https://github.com/${GITHUB_REPOSITORY}/releases/download/${kernel_current_release}"
            manifest="$RUNNER_TEMP/current-kernel-manifest.json"
            if curl -fsSL --retry 3 -o "$manifest" "$asset_base/kernel-manifest.json"; then
              if jq -e \
                --arg release "$kernel_current_release" \
                --arg kernel "$KERNEL_VERSION" \
                --arg source_url "${{ steps.kernel.outputs.kernel_source_url }}" \
                --arg source_sha "${{ steps.kernel.outputs.kernel_source_sha256 }}" \
                --arg config_url "https://raw.githubusercontent.com/firecracker-microvm/firecracker/86a2559b26a4b9a05405aeaa58bab0f7261d71bc/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config" \
                '.release == $release and
                 .upstream_kernel_version == $kernel and
                 .kernel_version == ("linux-" + $kernel + "-yeet") and
                 .kernel_source_url == $source_url and
                 .kernel_source_sha256 == $source_sha and
                 .kernel_config_url == $config_url and
                 .localversion == "-yeet" and
                 (.checksums.vmlinux | test("^[0-9a-f]{64}$")) and
                 (.checksums["kernel.config"] | test("^[0-9a-f]{64}$"))' \
                "$manifest" >/dev/null; then
                kernel_release="$kernel_current_release"
                kernel_release_build="false"
              fi
            fi
          fi
```

Write these values to `$GITHUB_OUTPUT`:

```bash
            echo "kernel_current_release=$kernel_current_release"
            echo "kernel_release=$kernel_release"
            echo "kernel_release_build=$kernel_release_build"
```

Update the summary:

```bash
            echo "- Kernel release: \`$kernel_release\`"
            echo "- Kernel release build: \`$kernel_release_build\`"
```

- [ ] **Step 5: Add the `build-kernel` job**

Insert this job after `detect`:

```yaml
  build-kernel:
    name: Build canonical kernel release
    needs: detect
    if: ${{ needs.detect.outputs.kernel_release_build == 'true' }}
    uses: ./.github/workflows/build-kernel.yml
    with:
      kernel_release: ${{ needs.detect.outputs.kernel_release }}
      kernel_version: ${{ needs.detect.outputs.kernel_version }}
      kernel_source_url: ${{ needs.detect.outputs.kernel_source_url }}
      kernel_source_sha256: ${{ needs.detect.outputs.kernel_source_sha256 }}
      kernel_config_url: https://raw.githubusercontent.com/firecracker-microvm/firecracker/86a2559b26a4b9a05405aeaa58bab0f7261d71bc/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config
      overwrite_release: false
    secrets: inherit
```

- [ ] **Step 6: Update Ubuntu and NixOS jobs to depend on kernel readiness**

Add `build-kernel` to `needs` for `build-ubuntu`. Change its condition to:

```yaml
    if: >-
      ${{
        always() &&
        needs.detect.outputs.ubuntu_build == 'true' &&
        (needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped')
      }}
```

Pass the kernel release:

```yaml
      kernel_release: ${{ needs.detect.outputs.kernel_release }}
```

Add `build-kernel` to `needs` for `build-nixos` and include the same kernel-ready condition alongside the package-ready condition:

```yaml
        (needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped') &&
```

Pass the kernel release to NixOS:

```yaml
      kernel_release: ${{ needs.detect.outputs.kernel_release }}
```

- [ ] **Step 7: Update package publishing job**

Change `publish-kernel-packages.needs` to:

```yaml
    needs:
      - detect
      - build-kernel
```

Change its condition to:

```yaml
      ${{
        always() &&
        (needs.detect.outputs.ubuntu_build == 'true' || needs.detect.outputs.nixos_build == 'true') &&
        (needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped')
      }}
```

Change workflow inputs to:

```yaml
      kernel_version: ${{ needs.detect.outputs.kernel_version }}
      kernel_release: ${{ needs.detect.outputs.kernel_release }}
```

- [ ] **Step 8: Run orchestration tests**

Run:

```bash
bash scripts/test-kernel-release-workflows.sh
```

Expected: PASS with no output.

- [ ] **Step 9: Commit workflow orchestration**

```bash
git add .github/workflows/sync-latest-stable-kernel.yml scripts/test-kernel-release-workflows.sh
git commit -m "kernel: orchestrate canonical kernel releases"
```

---

### Task 6: Domain Cleanup and Documentation

**Files:**
- Modify: `packages/kernel/deb/DEBIAN/control.in`
- Modify: `README.md`
- Modify: `scripts/test-kernel-release-workflows.sh`

- [ ] **Step 1: Fix the package maintainer domain**

In `packages/kernel/deb/DEBIAN/control.in`, change:

```text
Maintainer: yeet <maintainers@yeet[.]run>
```

to:

```text
Maintainer: yeet <maintainers@yeetrun.com>
```

- [ ] **Step 2: Add the domain guard to workflow tests**

Append this block to `scripts/test-kernel-release-workflows.sh`:

```bash
if git -C "$repo_root" grep -n 'yeet[.]run'; then
	echo "repository contains invalid yeet[.]run references" >&2
	exit 1
fi
```

- [ ] **Step 3: Document canonical kernel releases in README**

In `README.md`, add a short section before `## Publish a New Bundle`:

```markdown
## Canonical Kernel Releases

Latest-kernel automation publishes yeet-managed Firecracker kernels as
canonical GitHub releases named `kernel-linux-<upstream>-yeet-v<N>`.
Those releases own `vmlinux`, `kernel.config`, `kernel-manifest.json`, and
`kernel-checksums.txt`.

Ubuntu and NixOS image workflows accept `kernel_release`. When it is set, the
workflow downloads and verifies canonical kernel assets instead of compiling
the kernel. When it is empty, manual image builds keep the existing local
kernel-build fallback.

Kernel package publishing consumes the same canonical kernel release. The apt
repository and Nix package metadata must point at
`kernel-linux-<upstream>-yeet-v<N>` releases, not Ubuntu or NixOS image
releases.
```

In the Ubuntu workflow input list, add:

```markdown
- `kernel_release`: optional canonical kernel release to consume; leave empty
  to build the kernel locally
```

In the NixOS workflow input list, add:

```markdown
- `kernel_release`: optional canonical kernel release to consume; leave empty
  to build the kernel locally
```

In the package publishing docs, describe `kernel_release` as the source for apt
and Nix metadata.

- [ ] **Step 4: Run the domain guard**

Run:

```bash
bash scripts/test-kernel-release-workflows.sh
```

Expected: PASS with no output.

- [ ] **Step 5: Commit**

```bash
git add packages/kernel/deb/DEBIAN/control.in README.md scripts/test-kernel-release-workflows.sh
git commit -m "docs: document canonical kernel provenance"
```

---

### Task 7: Full Local Verification

**Files:**
- Inspect all files changed by Tasks 1-6.

- [ ] **Step 1: Run shell syntax checks**

Run:

```bash
bash -n scripts/resolve-kernel-release.sh
bash -n scripts/download-kernel-release.sh
bash -n scripts/publish-kernel-release-assets.sh
bash -n scripts/test-download-kernel-release.sh
bash -n scripts/test-latest-kernel-automation.sh
bash -n scripts/test-kernel-packages.sh
bash -n scripts/test-kernel-release-workflows.sh
bash -n scripts/test-publish-release-assets.sh
```

Expected: PASS with no output.

- [ ] **Step 2: Run static and helper tests**

Run:

```bash
bash scripts/test-latest-kernel-automation.sh
bash scripts/test-download-kernel-release.sh
bash scripts/test-kernel-packages.sh
bash scripts/test-kernel-release-workflows.sh
bash scripts/test-publish-release-assets.sh
```

Expected: PASS with no output.

- [ ] **Step 3: Run catalog verification**

Run:

```bash
scripts/verify-catalog.sh
```

Expected: PASS with no output. This downloads current latest image manifests.

- [ ] **Step 4: Check formatting-sensitive diffs**

Run:

```bash
git diff --check
git status --short --branch
test -z "$(git status --short)"
```

Expected: `git diff --check` prints no errors. `git status --short --branch` shows `main` ahead of `origin/main`. The final `test -z` command exits 0, confirming no uncommitted changes remain after the task commits.

---

### Task 8: Push and Live Workflow Verification

**Files:**
- No source edits unless GitHub Actions exposes a real defect.

- [ ] **Step 1: Push main**

Run:

```bash
git push origin main
```

Expected: Push succeeds.

- [ ] **Step 2: Trigger latest-kernel workflow**

Run:

```bash
gh workflow run sync-latest-stable-kernel.yml \
  --ref main \
  -f force=true \
  -f yeet_ref=main
```

Expected: GitHub accepts the workflow dispatch.

- [ ] **Step 3: Find and watch the run**

Run:

```bash
run_id="$(gh run list --workflow sync-latest-stable-kernel.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$run_id" --exit-status
```

Expected: The run completes successfully.

- [ ] **Step 4: Verify canonical kernel release**

Run:

```bash
gh release list --limit 20 | grep -E '^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[0-9]+'
```

Expected: A `kernel-linux-<version>-yeet-v<N>` release exists. If the workflow reused an existing matching release, the build job is skipped and the release still exists.

- [ ] **Step 5: Verify package metadata provenance**

Run:

```bash
git fetch origin main
git show origin/main:kernel-packages/metadata.nix | grep 'releases/download/kernel-linux-'
if git show origin/main:kernel-packages/metadata.nix | grep 'ubuntu-26.04-amd64-kernel'; then
  echo "metadata still points at Ubuntu image release" >&2
  exit 1
fi
```

Expected: Metadata points at canonical kernel release assets and not Ubuntu image release assets.

- [ ] **Step 6: Verify image kernel checksum alignment**

Fetch the latest manifests after the workflow publishes releases:

```bash
release_base="https://github.com/yeetrun/yeet-vm-images/releases/download"
curl -fsSL -o /tmp/ubuntu-manifest.json "$release_base/ubuntu-26.04-amd64-latest/manifest.json"
curl -fsSL -o /tmp/nixos-manifest.json "$release_base/nixos-26.05-amd64-latest/manifest.json"
jq -r '.checksums.vmlinux' /tmp/ubuntu-manifest.json
jq -r '.checksums.vmlinux' /tmp/nixos-manifest.json
```

Expected: The two printed checksums match when both images were rebuilt from the same canonical kernel release.

- [ ] **Step 7: Smoke disposable guests**

Create disposable Ubuntu and NixOS VMs from the updated catalog and check their booted kernels:

```bash
yeet run smoke-ubuntu vm://ubuntu/26.04
yeet run smoke-nixos vm://nixos/26.05
yeet ssh smoke-ubuntu -- uname -r
yeet ssh smoke-nixos -- uname -r
```

Expected: Both print the canonical `*-yeet` kernel version for the release the workflow selected.

- [ ] **Step 8: Clean up disposable guests**

Run:

```bash
yeet rm smoke-ubuntu --yes --clean-data --clean-config
yeet rm smoke-nixos --yes --clean-data --clean-config
```

Expected: Disposable VMs are removed. Do not delete non-smoke VMs.
