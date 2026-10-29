# Google Play listing: Frog Companion

Package: `com.tillo.frogcompanion` · version 1.0.0 (versionCode 1) · minimum Android 10 (API 29).

## Store listing

**App name** (30 max): `Frog Companion`

**Short description** (80 max):

> Copy on your Mac, paste on your Android phone, and back. Private, no account.

**Full description** (4,000 max):

> Frog Companion connects your Android phone to Frog on your Mac, so your clipboard follows you between them.
>
> Copy text or an image on your Mac and it's on your phone's clipboard a moment later. Copy something on your phone and send it to your Mac with one tap: from the app, the notification, a Quick Settings tile, the launcher shortcut, or the share sheet. Files from your Mac are saved to Downloads, and you can share any photo or file from your phone to your Mac.
>
> Works anywhere
> • Over Wi-Fi when your phone and Mac are on the same network.
> • Over Bluetooth when they aren't, so it keeps working on the train or a café's guest Wi-Fi.
>
> Private by design
> • Your phone talks straight to your own Mac. There is no server, no account and no cloud copy.
> • Everything is end-to-end encrypted with a key created when you pair, stored in Android's secure Keystore.
> • No ads, no analytics, no tracking.
>
> Android only lets the app on screen read the clipboard, so sending from your phone always takes one tap. Frog Companion never reads your clipboard in the background.
>
> Getting started
> 1. Open Frog on your Mac, then Settings → Phone → Pair a phone.
> 2. Open Frog Companion and scan the code.
>
> Frog Companion needs Frog for macOS.

**Category:** Productivity · **Contains ads:** No · **In-app purchases:** No

## Data safety

| Question | Answer |
| --- | --- |
| Does the app collect or share any of the required user data types? | **No.** |
| Is data encrypted in transit? | Yes (AES-256-GCM, keys from HKDF-SHA256, end to end between the user's own devices). |
| Can users request data deletion? | Not applicable: no data reaches the developer. Unpairing or uninstalling deletes everything on the phone. |

Explanation for review: Clipboard contents, shared files and the phone's device name are sent only to the Mac the user paired by scanning a QR code, directly over the local network or Bluetooth, end-to-end encrypted. Under Play's definitions this transfer between the user's own devices, initiated by the user, is neither collection nor sharing: nothing is sent to the developer or any third party. There are no servers, no analytics, no crash reporting SDKs and no advertising IDs.

## Permissions

| Permission | Why |
| --- | --- |
| `CAMERA` | Scanning the pairing QR code, only while the scanner is open. |
| `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT` | Finding and connecting to the paired Mac over Bluetooth LE when there is no shared Wi-Fi. Never used for location. |
| `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` (all `maxSdkVersion 30`) | The same Bluetooth link on Android 10 and 11, where scanning requires them. Location is never read. |
| `INTERNET`, `ACCESS_NETWORK_STATE`, `CHANGE_WIFI_MULTICAST_STATE` | Connecting to the Mac on the local network and finding it with Bonjour (NSD). |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE` | Keeping the encrypted link to the paired Mac open, so copies arrive while the app is closed. See the declaration below. |
| `POST_NOTIFICATIONS` | The ongoing connection notification with its Send clipboard button, and notices for received files. |
| `RECEIVE_BOOT_COMPLETED` | Reconnecting to the paired Mac after a restart. |

The app does not request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. When it is battery-optimized, it shows a card that opens the app's own App info page and tells the user to choose Battery → Unrestricted.

### Foreground service declaration (`connectedDevice`)

- **Feature:** Clipboard sync with the user's paired Mac.
- **Why it can't be deferred or interrupted:** The phone must keep a live, encrypted connection (TCP or Bluetooth LE GATT) to the user's own paired Mac to receive copies the moment they are made on the Mac. A copy is time-sensitive: the user copies on the Mac and pastes on the phone seconds later.
- **User-visible:** An ongoing notification shows the Mac's name and connection state, with a Send clipboard action. The service runs only while a Mac is paired and stops on unpair.
- **Video:** record the phone receiving a copy from the Mac with the app closed, then the notification.

## Screenshots needed

Phone, portrait, 1080 × 1920 or larger (9:16 or 9:19.5), at least 2 and up to 8. Use placeholder content only, no real names or devices:

1. Home with a connected Mac and a Recent list of text, an image and a file (light).
2. The same in dark mode.
3. Pairing: the Mac's QR code next to the phone's Pair with your Mac screen.
4. Sending: the notification with its Send clipboard button, or the Quick Settings tile.
5. The share sheet with "Send to Mac".
6. Settings, with the Send to Mac tile and the other ways to send.

Also: a 512 × 512 app icon (the adaptive icon's frog on Frog green) and a 1024 × 500 feature graphic.
