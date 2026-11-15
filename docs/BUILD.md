# Build

The original frontend build uses fixed public upstream sources, patches and SDK/runtime inputs recorded in `native/source-manifest.json`. See the native source preparation scripts in `scripts/native/`.

The integrated package recipe is `scripts/package/Build-Bundle.ps1`. It runs on a disposable Windows CI runner, verifies `installer/bundle-inputs.json`, extracts the pinned frontend and shared resources, assembles the fixed RymCp profile, indexes the actual payload and builds the NSIS installer.

The bundle input manifest must contain a complete scheme commit SHA and archive SHA256 before compilation. The workflow rebuilds the x64 and Win32 servers from the complete fixed frontend patch, using pinned librime C API headers and published engine export tables. Runtime engines and the other twelve native images retain their pinned 61052 bytes. The corresponding source archive includes the complete server sources, public build recipe, original frontend sources and exact scheme input.

Validation checks both server architectures, source and image hashes, mode notifications, icon switching, the actual extracted installer, fresh installation, installed-profile readiness, upgrades and preservation. Test data is fixed and synthetic. Physical Windows-host acceptance is recorded separately.

[Source inputs](SOURCES.md) | [User guide](PC.md)
