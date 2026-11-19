# Build

The original frontend build uses fixed public upstream sources, patches and SDK/runtime inputs recorded in `native/source-manifest.json`. See the native source preparation scripts in `scripts/native/`.

The integrated package recipe is `scripts/package/Build-Bundle.ps1`. It runs on a disposable Windows CI runner, verifies `installer/bundle-inputs.json`, extracts the pinned frontend and shared resources, assembles the fixed RymCp profile, indexes the actual payload and builds the NSIS installer.

The bundle input manifest pins the scheme commit and archive, the indexed math DLC, and the rebuild inputs. The workflow rebuilds TSF, legacy IME and the server for x64 and Win32 from the complete frontend patch. It uses pinned librime C API headers and published engine export tables. Runtime engines and the other installer programs retain their pinned 61052 bytes. The corresponding source archive includes the frontend patch, public build recipe, original frontend sources and exact scheme input.

Validation checks both frontend architectures, source and image hashes, the extracted installer, fresh installation, installed-profile readiness and upgrades. Upgrade checks include TSF DLLs already mapped by running processes, new 64-bit and 32-bit processes, and preservation of synthetic learning and custom configuration.

[Source inputs](SOURCES.md) | [User guide](PC.md)
