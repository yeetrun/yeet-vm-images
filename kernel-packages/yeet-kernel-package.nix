{ stdenvNoCC
, lib
, kernelVersion
, vmlinux
, kernelConfig
, vmlinuxSha256Raw
, kernelConfigSha256Raw
, releaseId
, manifestSha256
}:

stdenvNoCC.mkDerivation {
  pname = "yeet-vm-kernel";
  version = kernelVersion;

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    install -D -m0644 ${vmlinux} $out/lib/yeet-vm/kernels/linux-${kernelVersion}-yeet/vmlinux
    install -D -m0644 ${kernelConfig} $out/lib/yeet-vm/kernels/linux-${kernelVersion}-yeet/kernel.config
    install -D -m0644 /dev/stdin $out/share/yeet-vm/kernel/selected.json <<JSON
    {
      "schema_version": 2,
      "release_id": "${releaseId}",
      "manifest_sha256": "${manifestSha256}",
      "version": "linux-${kernelVersion}-yeet",
      "kernel": "$out/lib/yeet-vm/kernels/linux-${kernelVersion}-yeet/vmlinux",
      "kernel_config": "$out/lib/yeet-vm/kernels/linux-${kernelVersion}-yeet/kernel.config",
      "sha256": {
        "vmlinux": "${vmlinuxSha256Raw}",
        "kernel.config": "${kernelConfigSha256Raw}"
      }
    }
    JSON

    runHook postInstall
  '';

  meta = {
    description = "yeet Firecracker VM kernel artifact";
    platforms = lib.platforms.linux;
  };
}
