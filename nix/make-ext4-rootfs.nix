{ pkgs
, lib
, storePaths
, compressImage ? false
, zstd
, populateImageCommands ? ""
, volumeLabel
, uuid ? "44444444-4444-4444-8888-888888888888"
, e2fsprogs
, libfaketime
, perl
, fakeroot
, inodeHeadroomPercent ? 20
, dataHeadroomPercent ? 20
}:

let
  sdClosureInfo = pkgs.buildPackages.closureInfo { rootPaths = storePaths; };
in
pkgs.stdenv.mkDerivation {
  name = "ext4-fs.img${lib.optionalString compressImage ".zst"}";

  nativeBuildInputs = [
    e2fsprogs.bin
    libfaketime
    perl
    fakeroot
  ]
  ++ lib.optional compressImage zstd;

  buildCommand = ''
    ${if compressImage then "img=temp.img" else "img=$out"}
    (
    mkdir -p ./files
    ${populateImageCommands}
    )

    echo "Preparing store paths for image..."

    mkdir -p ./rootImage/nix/store

    xargs -I % cp -a --reflink=auto % -t ./rootImage/nix/store/ < ${sdClosureInfo}/store-paths
    (
      GLOBIGNORE=".:.."
      shopt -u dotglob

      for f in ./files/*; do
          cp -a --reflink=auto -t ./rootImage/ "$f"
      done
    )

    cp ${sdClosureInfo}/registration ./rootImage/nix-path-registration

    numInodes=$(find ./rootImage | wc -l)
    mkfsInodes=$(( (numInodes * (100 + ${toString inodeHeadroomPercent}) + 99) / 100 ))
    numDataBlocks=$(du -s -c -B 4096 --apparent-size ./rootImage | tail -1 | awk '{ print int($1 * (100 + ${toString dataHeadroomPercent}) / 100) }')
    bytes=$((2 * 4096 * $mkfsInodes + 4096 * $numDataBlocks))
    echo "Creating an EXT4 image of $bytes bytes (numInodes=$numInodes, mkfsInodes=$mkfsInodes, numDataBlocks=$numDataBlocks)"

    mebibyte=$(( 1024 * 1024 ))
    if (( bytes % mebibyte )); then
      bytes=$(( ( bytes / mebibyte + 1) * mebibyte ))
    fi

    truncate -s $bytes $img

    faketime -f "1970-01-01 00:00:01" fakeroot mkfs.ext4 -N $mkfsInodes -L ${volumeLabel} -U ${uuid} -d ./rootImage $img

    export EXT2FS_NO_MTAB_OK=yes
    if ! fsck.ext4 -n -f $img; then
      echo "--- Fsck failed for EXT4 image of $bytes bytes (numInodes=$numInodes, mkfsInodes=$mkfsInodes, numDataBlocks=$numDataBlocks) ---"
      cat errorlog
      return 1
    fi

    resize2fs -M $img

    new_size=$(dumpe2fs -h $img | awk -F: \
      '/Block count/{count=$2} /Block size/{size=$2} END{print (count*size+16*2**20)/size}')

    resize2fs $img $new_size

    if [ ${toString compressImage} ]; then
      echo "Compressing image"
      zstd -T$NIX_BUILD_CORES -v --no-progress ./$img -o $out
    fi
  '';
}
