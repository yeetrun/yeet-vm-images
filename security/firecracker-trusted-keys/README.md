# Reviewed Firecracker signing keys

Place reviewed, armored OpenPGP public-key files in this directory with an
`.asc` suffix. The runtime downloader imports only these files into a new
private keyring for each ingest. It never uses an ambient user or runner
keyring. A key's full primary fingerprint must also appear in
`security/firecracker-trusted-signers.txt` before its verified tags receive
`signed` status.

The directory is intentionally empty until upstream signer key material has
been reviewed. Signed and signer-rotation ingests fail closed while it remains
empty; explicitly approved unsigned tags remain separately recorded as
`unsigned-approved`.
