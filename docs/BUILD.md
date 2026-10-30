# Build Rime Stellae

The source inventory pins the official Weasel base, the complete frontend patch, the two engine variants, plugin sources and build dependencies. Build products are generated in a clean Windows MSVC environment. Source assembly, native compilation, controlled input tests and installer tests are separate checks.

## Components

| Component | Version or role |
| --- | --- |
| TSF, Server, Deployer, Setup and classic IME | 0.17.4.61052, x64 and Win32 as declared per product |
| Runtime engine, x64 | N01 with step-only Lua GC |
| Runtime engine, Win32 | R5 |
| Frontend SDK | R5, rebuilt for the matching architecture |
| Compiler | MSVC v143 on a hosted Windows runner |
| Installer | NSIS, with the source in `installer/` |

Use the repository's native build workflow and its pinned source manifest. Build both engine variants required by the package, assemble the frontend, then build the declared product targets. Package preparation selects only the listed shared resources from the fixed public Weasel distribution. It uses the empty schema list in this repository and includes dependency notices.

The native entry points are:

```powershell
./scripts/native/Prepare-Sources.ps1 -Variant stellae-61052 -Destination <new-source-directory>
./scripts/native/Prepare-Sources.ps1 -Variant engine-r5 -Destination <new-engine-directory>
./scripts/native/Prepare-Sources.ps1 -Variant engine-n01 -Destination <another-new-engine-directory>
./scripts/native/Build-Engine.ps1 -Variant engine-r5 -Architecture x86 -SourcePath <engine-source> -CacheDirectory <cache> -OutputDirectory <new-sdk-output>
./scripts/native/Build-Weasel.ps1 -SourcePath <frontend-source> -SdkRoot <same-run-sdk-directory> -CacheDirectory <cache> -OutputDirectory <new-frontend-output>
```

Build R5 for both architectures and N01 for x64. The SDK directory contains `engine-r5-x64`, `engine-r5-x86` and `engine-n01-x64` from the same source manifest, commit and workflow run. The scripts reject mismatched provenance. Product output is separate from the source tree.

The installer source and packaging overlays accompany the assembled frontend source. Editable product icon assets are in [assets/icon](../assets/icon/README.md). Run source and package verification before publishing the installer.

## Verification

The build workflow checks patch application and source hashes, compiles the declared architectures, runs controlled key fixtures, restores clean product outputs and checks the actual package contents. Installer tests run only on disposable hosted Windows runners, using synthetic configuration and data.

Runtime and SDK roles are recorded separately. A successful source assembly does not establish compilation or application compatibility. Existing controlled tests do not establish that every host application and Windows configuration has been tested. ARM64 products are not part of this release.

## Source availability

The repository contains the project patches, build scripts, tests, packaging source and fixed source references. Published binary releases also provide a corresponding source bundle. See [SOURCES.md](SOURCES.md) for upstream downloads and [the license inventory](../licenses/file-licenses.json) for retained terms.

Do not replace a pinned engine or SDK silently. Such a change needs matching build and behavior checks. The x64 N01 and Win32 R5 variants have distinct source modifications.
