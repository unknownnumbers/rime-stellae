# Build

The original frontend build uses fixed public upstream sources, patches and SDK/runtime inputs recorded in `native/source-manifest.json`. See the native source preparation scripts in `scripts/native/`.

The integrated package recipe is `scripts/package/Build-Bundle.ps1`. It runs on a disposable Windows CI runner, verifies `installer/bundle-inputs.json`, extracts the pinned frontend and shared resources, assembles the fixed RymCp profile, indexes the actual payload and builds the NSIS installer.

The bundle input manifest pins the scheme commit and archive, the indexed math DLC, and the rebuild inputs. The workflow rebuilds TSF, legacy IME and the server for x64 and Win32 from the complete frontend patch. It uses pinned librime C API headers and published engine export tables. The workflow also compiles the N01 x64 and R5 Win32 runtimes and verifies their hashes and architectures in the finished installer. Both runtimes use full garbage collection when a Lua translation is released. The corresponding source archive includes the frontend patch, original frontend sources, assembled engine sources and exact scheme input.

Validation checks both frontend architectures, source and image hashes, the extracted installer, fresh installation, installed-profile readiness and upgrades. The installed-profile tests exercise the bundled N01 and R5 runtimes. Upgrade checks cover preservation of synthetic learning and custom configuration.

[Source inputs](SOURCES.md) | [User guide](PC.md)
