# Reviewed Firecracker signing keys

Place reviewed, armored OpenPGP public-key files in this directory with an
`.asc` suffix. The runtime downloader imports only these files into a new
private keyring for each ingest. It never uses an ambient user or runner
keyring. A key's full primary fingerprint must also appear in
`security/firecracker-trusted-signers.txt` before its verified tags receive
`signed` status.

Each key is added only after its full primary fingerprint, verified GitHub
identity, and an upstream release-tag signature have been reviewed. Signed and
signer-rotation ingests fail closed when the matching reviewed key is absent;
explicitly approved unsigned tags remain separately recorded as
`unsigned-approved`.

## Current reviewed signer

- Jay Chung (`not4s`), `jaehoc@amazon.com`
- Primary fingerprint: `192778948C7AC9DE9EE677BFC36283F6CAA7410D`
- Key source: <https://github.com/not4s.gpg>
- Reviewed against Firecracker tag `v1.16.1`, annotated tag object
  `e527ccfc54495dabac96f1835db61a40afa15115`, which resolves to commit
  `2038188f145fb81b8d098147a10e9d9f392fd22f`
- GitHub's upstream tag page reports the same signer and key ID as verified:
  <https://github.com/firecracker-microvm/firecracker/releases/tag/v1.16.1>
