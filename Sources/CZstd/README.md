# CZstd

This SwiftPM C target vendors the single-file Zstandard **decompressor** from
[facebook/zstd](https://github.com/facebook/zstd) release `v1.5.7`. The source archive is
`https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz` with SHA-256
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`.

CodexBar only needs to read Codex rollouts that Codex archives as `*.jsonl.zst`, so the target carries the decoder
alone (no compressor, no legacy formats, no assembly):

- `zstddeclib.c`: generated from the release with
  `build/single_file_libs/combine.sh -r lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c`
  (SHA-256 `e1dc239cb4bcf3c00a0462fdbe5f3e3c78f907c4f8cb02c048807d754bdc51b5`).
- `include/zstd.h` and `include/zstd_errors.h`: the release's public headers, unmodified
  (SHA-256 `9b4bc8245565c98ccfc61c07749928b57e7c0f6fddb0530c4f6aa1971893d88b` and
  `66a8c3f71d12ea6e797e4f622f31f3f8f81c41b36f48cad4f5de7d8bfb6aac0a`).
- `LICENSE`: the upstream BSD license (zstd is dual BSD/GPLv2; CodexBar uses it under BSD).
