# silo-mac-build

Builds of Spark, this fork of Silo with its own changes (for example the missing-seasons
feature), for every platform. The apps are rebranded at build time by each fork's
`fork/apply-brand.sh`; see `fork/README.md` in `silo-apple` and `silo-android`.

| Platform | Fork branch | Build | Output |
|---|---|---|---|
| Server | `Joloxx9/silo-server` `main` | `fork-image.yml` in that repo | `ghcr.io/joloxx9/silo-server:latest` |
| macOS | `Joloxx9/silo-apple` `fork-build` | `mac-app.yml` here | `Silo-macOS.zip` in Releases |
| iOS, tvOS | `Joloxx9/silo-apple` `fork-build` | `sideload-ipa.yml` here | unsigned `.ipa` files in Releases |
| App Store (iOS, tvOS, macOS) | `Joloxx9/silo-apple` `fork-build` | `store-apple.yml` here | TestFlight / App Store Connect |
| Google Play | `Joloxx9/silo-android` `fork-build` | `fork-store.yml` in that repo | Play track |
| Android phone, TV | `Joloxx9/silo-android` `fork-build` | `fork-build-apk.yml` in that repo (on push) | debug APKs in that repo's Releases |

The `silo-apple` fork has Actions disabled, so its builds run here.

## Update everything

```sh
./sync-and-build.sh --check   # what upstream added, and whether it merges cleanly
./sync-and-build.sh           # merge upstream main into each fork branch, push, build all
```

`--no-build` merges and pushes only, `--build-only` rebuilds what is already pushed, and
`--only server,apple,android` limits the run. A repo whose merge conflicts is left as it
was and listed at the end: resolve the merge by hand, push, then run `--build-only`.

When the server's settings manifest (`contracts/settings/v1/manifest.json`) changes,
re-vendor it into the apps: regenerate with `go run ./cmd/settingsgen -lang swift` /
`-lang kotlin` from the server repo and copy `manifest.json` and `conformance.json` into
the apps' settings fixtures.

## Install

- macOS: unzip, move `Spark.app` to Applications, run `xattr -cr /Applications/Spark.app`.
- iOS: re-sign the IPA with AltStore, SideStore or Sideloadly.
- tvOS: re-sign and install with Xcode on a Mac (Window > Devices and Simulators).
- Android: the APKs install next to the official Silo app (own application ID).

## Brand art

`brand/generate.py` draws the placeholder icons (Poppins Bold, OFL) into each fork's
`fork/overlay/`: `uv run --with pillow python brand/generate.py <silo-apple> <silo-android>`.
