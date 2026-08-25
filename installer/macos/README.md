# GeomWhisper macOS installer build

This directory contains the files required to build the macOS application bundle, ZIP archive, and DMG installer for GeomWhisper. The application source is read from the [repository root](../..); it is not duplicated here.

## Release baseline

- Application version: `1.0.1`
- Release tag: `v1.0.1`
- Release commit: `754226ac7f1ed440894cfdca8addae4693925fd9`
- Minimum macOS version: macOS 11
- R requirement: R 4.4 or later
- Supported Mac architectures: Apple Silicon and Intel, with the matching R distribution installed

Each build records its source repository and commit in `GeomWhisper.app/Contents/Resources/app/SOURCE_COMMIT.txt`.

## Directory contents

```text
installer/macos/
├── README.md
├── Info.plist
├── icon.icns
├── launcher
├── build_app.sh
├── build_dmg.sh
└── dist/                # generated; do not commit
```

## Build

Run the following commands from the repository root:

```bash
./installer/macos/build_app.sh
./installer/macos/build_dmg.sh
```

By default, `build_app.sh` uses the repository root as the application source. To build from another checkout, pass its absolute path:

```bash
./installer/macos/build_app.sh /absolute/path/to/GeomWhisper
./installer/macos/build_dmg.sh
```

For a release, build from the reviewed release tag rather than from an untagged working tree. The expected `v1.0.1` outputs are:

```text
installer/macos/dist/GeomWhisper.app
installer/macos/dist/GeomWhisper-macOS-1.0.1.zip
installer/macos/dist/GeomWhisper-macOS-1.0.1.dmg
installer/macos/dist/SHA256SUMS.txt
```

`build_dmg.sh` regenerates `SHA256SUMS.txt` after creating the DMG.

## Installation

1. Install R 4.4 or later from <https://cran.r-project.org/bin/macosx/> using the installer that matches the Mac's architecture.
2. Open the DMG and drag `GeomWhisper.app` to Applications. Alternatively, unzip the ZIP and move the application to Applications.
3. Open GeomWhisper. On first launch, allow time for missing R packages to install in the user's R library.
4. Select an available hosted model provider or a local Ollama model in the application.

Internet access is required when R packages are missing. Chrome or Edge is recommended for voice input; typed chat can be used in another browser.

Application logs are written to:

```text
~/Library/Logs/GeomWhisper/launch.log
~/Library/Logs/GeomWhisper/shiny.log
```

Provider API keys and model selections are stored in the user's R configuration directory. They are not embedded in the application bundle.

## Verification

Run these checks before publishing:

```bash
bash -n installer/macos/launcher \
  installer/macos/build_app.sh \
  installer/macos/build_dmg.sh
plutil -lint installer/macos/dist/GeomWhisper.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 \
  installer/macos/dist/GeomWhisper.app
unzip -tq installer/macos/dist/GeomWhisper-macOS-1.0.1.zip
hdiutil verify installer/macos/dist/GeomWhisper-macOS-1.0.1.dmg
(cd installer/macos/dist && shasum -a 256 -c SHA256SUMS.txt)
```

For a noninteractive startup check that does not open a browser:

```bash
GEOMWHISPER_NO_BROWSER=1 \
GEOMWHISPER_NO_DIALOGS=1 \
GEOMWHISPER_TEST_EXIT_AFTER_READY=1 \
installer/macos/dist/GeomWhisper.app/Contents/MacOS/launcher
```

The startup check may install missing R packages. It does not require or use an LLM API key.

## Publishing

Publish these generated files as GitHub Release assets:

```text
GeomWhisper-macOS-1.0.1.dmg
GeomWhisper-macOS-1.0.1.zip
SHA256SUMS.txt
```

If the repository continues to track installer binaries, copy the verified DMG beside the Windows installers:

```bash
cp installer/macos/dist/GeomWhisper-macOS-1.0.1.dmg installer/
```

Do not commit `installer/macos/dist/`, the unpacked `.app`, user configuration, logs, `.env` files, `.Rhistory`, or `.DS_Store` files.

## Signing and notarization

The build script applies an ad-hoc signature for local bundle-integrity checks. It is not an Apple Developer ID signature, and the generated application and DMG are not notarized.

For a public macOS release:

1. Sign the application with a `Developer ID Application` certificate.
2. Build and sign the distribution artifact.
3. Submit it to Apple's notarization service with `notarytool`.
4. Staple the notarization ticket.
5. Repeat the integrity, Gatekeeper, startup, and checksum checks before publishing.

Do not describe an ad-hoc signed build as notarized or Gatekeeper-approved.
