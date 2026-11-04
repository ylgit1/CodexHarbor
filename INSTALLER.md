# Codex Harbor v0.1.30

Apple Silicon (arm64), macOS 14 or newer.

- Source commit: 25c0f7e63b97aa3e5bd9037f49566fdc742eee97
- Verified SHA-256: 8e27a4a5326fe4631fb4c5b53a0ea38a4f56fc44f4956927acb2ff47eec12d6d
- Versioned DMG: v0.1.30/Codex-Harbor-v0.1.30-arm64.dmg
- Latest DMG: latest/Codex-Harbor-arm64.dmg

This release fixes VPN Gate node country labels by retaining publisher
country as unverified source metadata and preferring observed exit
GeoIP when available. Adds a backup SOCKS-only IP echo provider and
independent GeoIP lookup for the observed exit IP.
The app includes Xray/Mihomo and is ad-hoc signed, not Apple-notarized.
