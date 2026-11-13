# Build

The original frontend build uses fixed public upstream sources, patches and SDK/runtime inputs recorded in `native/source-manifest.json`. See the native source preparation scripts in `scripts/native/`.

The integrated package recipe is `scripts/package/Build-Bundle.ps1`. It runs on a disposable Windows CI runner, verifies `installer/bundle-inputs.json`, extracts the pinned frontend and shared resources, assembles the fixed RymCp profile, indexes the actual payload and builds the NSIS installer.

The bundle input manifest must contain a complete scheme commit SHA and archive SHA256 before compilation. The frontend production binaries remain the pinned 61052 files. The corresponding source archive includes both frontend source generations and the exact scheme input.

Validation checks the actual extracted installer, payload manifests, original PE hashes, fresh installation, installed-profile readiness, upgrades and preservation. Test data is fixed and synthetic. Physical Windows-host acceptance is recorded separately.

[Source inputs](SOURCES.md) | [User guide](PC.md)
