# Aigo for iPhone

[![Build unsigned IPA](https://github.com/YaselMS/aigo-ios/actions/workflows/ios.yml/badge.svg)](https://github.com/YaselMS/aigo-ios/actions/workflows/ios.yml)

The iPhone app for the Aigo host on your Windows PC. It pairs with the PC
once, then talks to it over TLS pinned to that PC's certificate, so it only
ever connects to your machine. While a task runs, a Live Activity shows its
progress on the Lock Screen and in the Dynamic Island.

Requires iOS 17 or later.

## Get the app (IPA)

Every build produces an **unsigned** IPA. You sign it yourself (see below).

- **Latest build:** open the [Actions tab](https://github.com/YaselMS/aigo-ios/actions/workflows/ios.yml),
  click the newest green **Build unsigned IPA** run, and download the
  **Aigo-unsigned-ipa** artifact at the bottom of the page. It downloads as a
  `.zip`; unzip it to get `Aigo-unsigned.ipa` (and a `.sha256` checksum).
  Artifacts are kept for 30 days and you need to be signed in to GitHub.
- **Tagged versions:** download `Aigo-unsigned.ipa` from the
  [Releases page](https://github.com/YaselMS/aigo-ios/releases). No sign-in needed.

## Install with Signulous

1. In Signulous, upload `Aigo-unsigned.ipa`.
2. Sign it for your registered device.
3. Install it on the iPhone from Signulous. If iOS asks you to trust the
   developer or turn on Developer Mode, follow the prompt in Settings.

To update, sign and install a newer IPA the same way.

**What works and what does not:**

- Live Activities and the Dynamic Island work. They are driven by the app
  while it is connected to your PC.
- Remote push notifications do **not** work with a signing service. They need
  an APNs key from your own paid Apple Developer account, which Signulous
  cannot provide. For alerts while the app is closed, set up
  [ntfy](https://ntfy.sh) in Aigo on the PC and install the ntfy app on the phone.

## First run

1. On the PC, open Aigo and go to **Settings → Remote access**.
2. Turn on **remote access**, then click **Pair a device**. Aigo shows a QR code
   and a 6-digit code.
3. When Windows asks whether to allow Aigo through Windows Firewall, click
   **Allow**. This is a one-time prompt and needs an administrator.
4. Make sure the phone and the PC are on the same Wi-Fi network.
5. In the iPhone app, scan the QR code. If you can't scan, type the
   `host:port`, the 6-digit code, and the certificate fingerprint shown on the PC.

If the phone can't connect, check that both devices are on the same network
and that the firewall prompt was allowed (Windows Security → Firewall &
network protection → Allow an app through firewall).

## Build it yourself (Mac)

You need Xcode 16 or later and [Homebrew](https://brew.sh).

```sh
brew install xcodegen
xcodegen generate --spec ios/project.yml   # creates ios/Aigo.xcodeproj (not committed)
open ios/Aigo.xcodeproj                    # run on a device or simulator from Xcode
```

To produce the same unsigned IPA as CI:

```sh
xcodebuild -project ios/Aigo.xcodeproj -scheme Aigo -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/Aigo.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  archive

scripts/package-ipa.sh build/Aigo.xcarchive build/Aigo-unsigned.ipa
scripts/verify-ipa.sh build/Aigo-unsigned.ipa
```

Edit `ios/project.yml`, not the generated project. Never commit certificates,
provisioning profiles, or keys (`.p12`, `.p8`, `.mobileprovision`); CI rejects them.

To publish a release, push a tag such as `v1.0.0`. CI builds the IPA and
attaches it to a GitHub Release.

## License

[MIT](LICENSE)
