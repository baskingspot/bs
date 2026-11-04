# Changelog

Changes a user of bs notices, newest first, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

## [Unreleased]

### Changed

- zap is now bs. The binary is `bs`, the environment variables are `BS_*`, and the caches are `<global cache>/bs`, `.zig-cache/bs`, and `~/.cache/bs`. Old `ZAP_*` variables are ignored; delete `~/.cache/zig/zap`, `.zig-cache/zap`, and `~/.cache/zap`.
