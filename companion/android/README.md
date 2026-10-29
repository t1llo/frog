# Frog Companion for Android

Frog Companion is the Android side of Frog's **Phone** feature. It keeps one Android phone and Frog on your Mac in sync:

- What you copy on the Mac lands on the phone's clipboard. Files are saved to Downloads.
- The phone sends its clipboard, shared text, photos and files to the Mac with one tap: from the app, the notification, a Quick Settings tile, the launcher shortcut or the share sheet.
- Android only lets an app read the clipboard while it is on screen, so sending from the phone always takes a tap. There is no background clipboard reading.

It connects over Wi-Fi when the phone and Mac share a network, and over Bluetooth LE when they don't. Everything is end-to-end encrypted with a key made during pairing. There is no server and no account.

The wire format is specified in [docs/companion-protocol.md](../../docs/companion-protocol.md). The Mac and Android implementations check the same test vector.

## Pairing

1. Open Frog on your Mac, then **Settings → Phone → Pair a phone**.
2. Open Frog Companion on the phone and scan the QR code.

## Building

Requirements: JDK 17 or later and the Android SDK (compile SDK 37). Point the build at them with environment variables or a `local.properties` file (`sdk.dir=...`, never committed):

```sh
export JAVA_HOME=/path/to/jdk
export ANDROID_HOME=/path/to/android/sdk

./gradlew :app:assembleDebug :app:testDebugUnitTest
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`. Install it on a phone with USB debugging on:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### Release builds

```sh
./gradlew :app:bundleRelease   # app/build/outputs/bundle/release/app-release.aab
./gradlew :app:assembleRelease # app/build/outputs/apk/release/
```

Release builds are minified with R8. They are signed when signing values are available, from a `keystore.properties` file next to `settings.gradle.kts`:

```properties
storeFile=/path/to/upload-keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

or from the environment: `FROG_COMPANION_KEYSTORE`, `FROG_COMPANION_KEYSTORE_PASSWORD`, `FROG_COMPANION_KEY_ALIAS`, `FROG_COMPANION_KEY_PASSWORD`. Without them the release build is left unsigned. `keystore.properties`, `*.jks` and `*.keystore` are ignored by Git; keep keys out of this repository.

## Layout

```
app/src/main/java/xyz/beffa/frog/companion/
  protocol/   handshake, HKDF keys, AES-GCM frames, messages, pairing QR
  transport/  TCP, Bluetooth LE GATT pipe, NSD discovery, the session
  service/    foreground service, connection controller, notifications
  clipboard/  reading and writing the clipboard, share target, tile, sender activity
  data/       pairing store (secret wrapped by an Android Keystore key), history
  ui/         Compose screens and Frog's design tokens (Theme.kt)
app/src/test/ protocol tests, including the cross-platform vector
```

The application ID is `com.tillo.frogcompanion`; the Kotlin package is `xyz.beffa.frog.companion`.
