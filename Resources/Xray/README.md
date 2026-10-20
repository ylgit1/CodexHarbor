# Bundled Xray runtime

- Upstream: https://github.com/XTLS/Xray-core
- Release: v26.3.27
- macOS arm64 archive: `Xray-macos-arm64-v8a.zip`
- Upstream archive SHA-256: `2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf`
- License: Mozilla Public License 2.0 (see the upstream release repository)

`Scripts/build-app.sh` verifies the individual bundled files against
`arm64/SHA256SUMS` before copying them into the signed application bundle.
