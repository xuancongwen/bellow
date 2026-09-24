# Auto-update plan (Sparkle)

Written 2026-09-23, parked. Pick this up when preparing the app for sale; it
is about half a day of work once the keys exist. Until then, updates are
manual: run the installer again or download the new DMG.

## Why Sparkle

Sparkle is the standard updater for Mac apps distributed outside the App
Store (Superwhisper, MacWhisper, and VoiceInk use it). It fits this project:

- Swift Package dependency; no Xcode project needed.
- Updates are verified with Sparkle's own EdDSA signature, independent of
  Apple signing, so it works with ad-hoc or self-signed builds. Sparkle also
  clears the quarantine flag on the installed update, so Gatekeeper never
  reappears after the first install.
- Beta channel support: release candidates can go to testers while a public
  channel sees only stable versions.
- The feed is a static XML file (the appcast) that the release workflow can
  generate and publish through the existing GitHub Pages deploy. GitHub
  Releases keeps hosting the DMG.

Rolling our own (poll the GitHub API, download, replace the bundle) would
avoid the dependency but re-implement signature checks, atomic replacement,
relaunch, and release notes; not worth it.

## The signing prerequisite

macOS ties the Accessibility and Microphone grants to the app's code
signature. An ad-hoc signature is unique per build, so every auto-update
would look like a new app and the grants would lapse. Before shipping
auto-updates, sign with a stable identity:

- **Self-signed certificate** (free, stable identity, Gatekeeper still
  blocks the first manual install as today), or
- **Developer ID** (paid; README "Signing and notarization"), which also
  notarizes.

Either way the switch from ad-hoc re-prompts permissions once. The CI
certificate-import step in `.github/workflows/macos.yml` currently accepts
only a `Developer ID Application` identity; for a self-signed certificate,
change the `grep` to match the certificate's common name (or any identity)
and add `security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN"
signing.crt` after the import, exporting the `.crt` from the `.p12` with
`openssl pkcs12 -in cert.p12 -clcerts -nokeys`.

## Key generation (run on the developer's Mac, never in the repo)

Self-signed certificate:

```sh
mkdir -p ~/bellowflow-keys && cd ~/bellowflow-keys
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout signing.key -out signing.crt \
  -subj "/CN=BellowFlow Signing/O=Sam Wen" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -inkey signing.key -in signing.crt -out signing.p12 -name "BellowFlow Signing"
security import signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db signing.crt
security find-identity -v -p codesigning | grep "BellowFlow Signing"
```

If `-addext` is rejected (old LibreSSL), use Homebrew's openssl. Skip this
block entirely if going straight to Developer ID.

Sparkle EdDSA key:

```sh
cd ~/bellowflow-keys
curl -fsSL "$(curl -fsSL https://api.github.com/repos/sparkle-project/Sparkle/releases/latest | grep browser_download_url | grep 'Sparkle-.*\.tar\.xz' | head -1 | cut -d'"' -f4)" -o sparkle.tar.xz
mkdir sparkle && tar -xf sparkle.tar.xz -C sparkle
./sparkle/bin/generate_keys            # stores the private key in the login keychain, prints the public key
./sparkle/bin/generate_keys -x sparkle-private.key   # export for CI
```

Keep `signing.p12`, its password, and `sparkle-private.key` in a password
manager, then delete the directory. Losing the Sparkle private key strands
every installed copy: they trust only the public key baked into the app.

Repository secrets (Settings → Secrets and variables → Actions):
`APPLE_CERTIFICATE_P12` (`base64 -i signing.p12`), `APPLE_CERTIFICATE_PASSWORD`,
`SPARKLE_PRIVATE_KEY` (file contents). The first two are the names the
workflow already reads; replace their values when moving to Developer ID.

## Integration steps

1. **Package.swift**: add
   `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")`
   and `.product(name: "Sparkle", package: "Sparkle")` to the BellowFlow
   target. Sparkle's SPM product is a binary XCFramework, which `swift build`
   handles.
2. **Info.plist**: `SUFeedURL` =
   `https://xuancongwen.github.io/bellowflow/appcast.xml`, `SUPublicEDKey` =
   the public key from `generate_keys`, `SUEnableAutomaticChecks` = true.
   No XPC services or `SUEnableInstallerLauncherService` are needed because
   the app is not sandboxed.
3. **Code** (`main.swift`): keep a
   `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`
   on the delegate and add a "Check for Updates…" menu item whose action is
   `checkForUpdates(_:)` on the controller. For the beta channel, implement
   `SPUUpdaterDelegate.allowedChannels(for:)` returning `["beta"]` when a
   user default is set (add a checkbox to the setup window). Sparkle relaunches
   the app after installing; `applicationWillTerminate` already stops the
   engines.
4. **Build script**: `swift build` links Sparkle by rpath. Copy
   `Sparkle.framework` from the build products into
   `BellowFlow.app/Contents/Frameworks/` and link the executable with
   `-Xlinker -rpath -Xlinker @executable_path/../Frameworks`. Sign the
   framework's nested pieces (`Autoupdate`, `Updater.app`, XPC services) before
   the outer app; the existing loop over Mach-O files covers them but should
   sign Sparkle's binaries without the app's entitlements. Add
   `Frameworks/Sparkle.framework` to `audit-bundle.py`'s required list.
5. **Release workflow**: after the DMG is built, run Sparkle's
   `sign_update` / `generate_appcast` with the private key from the secret to
   produce `site/appcast.xml` (with `<sparkle:channel>beta</sparkle:channel>`
   on pre-releases and the GitHub release URL as the enclosure). Commit the
   appcast to `master` from the workflow (it already has `contents: write`),
   which triggers the Pages deploy. Sparkle accepts a DMG enclosure; a zip
   installs faster and could be attached as a second asset.
6. **Test before tagging**: build two local versions, host the appcast on a
   local server or a scratch Pages deploy, and confirm the older one updates,
   relaunches, and keeps its Accessibility grant.

## Rollout notes

- The first Sparkle-enabled version cannot update from a version without
  Sparkle; testers install it by hand once.
- Sparkle adds roughly 3 MB to the bundle and a menu item.
- `VERSION` already drives `CFBundleShortVersionString`; Sparkle compares
  `CFBundleVersion`, so the build number stamped from the date keeps
  increasing as required.
- The third-party notices need a Sparkle entry (MIT, Sparkle Project) and
  the bundle its license text.
