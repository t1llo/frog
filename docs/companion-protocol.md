# Frog Companion protocol, version 1

Frog's Phone feature moves clipboard items between Frog on a Mac and the Frog Companion app on paired Android phones. The Mac is always the
**server**; the phone is always the **client**. The same byte stream runs over two transports:
TCP on a shared Wi-Fi network, and a Bluetooth LE GATT pipe when there is no shared network.

All integers are unsigned big-endian. "base64url" means RFC 4648 §5 without padding.

## 1. Identities and pairing

- Every install has a random **device ID**: a UUID, stored as 16 raw bytes on the wire and as a
  lowercase hyphenated string elsewhere.
- A pairing has one **secret**: 32 random bytes made by the Mac.

The Mac shows a QR code whose text is:

```
frog://pair?v=1&id=<mac uuid>&n=<mac name, percent-encoded>&k=<secret base64url>&p=<tcp port>&h=<comma-separated IPv4 addresses>
```

While the QR code is shown, that secret is the Mac's **pending secret**. The phone stores the Mac's
ID, name, secret, port and hosts, then connects. When the Mac receives a handshake from a client ID
it does not know, it uses the pending secret; if that client's `hello` decrypts, the Mac stores
`{clientId, name, secret}` permanently and clears the pending secret. A client ID the Mac does not
know while no pending secret exists is disconnected immediately.

## 2. Handshake (cleartext)

Each side sends exactly 52 bytes:

| Bytes | Field |
| --- | --- |
| 4 | magic `FRG1` (ASCII `46 52 47 31`) |
| 16 | sender device ID |
| 32 | random nonce |

The client sends first. The server reads the client's 52 bytes, picks the secret for that client
ID (section 1), then sends its own 52 bytes. The client disconnects if the server ID is not the
paired Mac's ID. Either side disconnects on a wrong magic.

## 3. Keys

```
salt   = clientNonce || serverNonce                       (64 bytes)
c2sKey = HKDF-SHA256(ikm = secret, salt, info = "frog-companion/v1/c2s", L = 32)
s2cKey = HKDF-SHA256(ikm = secret, salt, info = "frog-companion/v1/s2c", L = 32)
```

The client encrypts with `c2sKey` and decrypts with `s2cKey`; the server does the opposite.

## 4. Frames

After the handshake every unit on the wire is a frame:

| Bytes | Field |
| --- | --- |
| 4 | `N`, length of `sealed` |
| N | `sealed` = AES-256-GCM ciphertext followed by the 16-byte tag |

- Nonce (12 bytes, never sent): 4 zero bytes followed by a u64 counter. Each direction has its own
  counter, starting at 0 for the first frame and adding 1 per frame.
- No additional authenticated data.
- `N` must be at least 16 and at most 268,436,480 (256 MiB + 1 KiB). Anything else, or a frame
  that fails to decrypt, closes the connection.

## 5. Messages (the plaintext of a frame)

| Bytes | Field |
| --- | --- |
| 4 | `H`, header length |
| H | header, UTF-8 JSON object |
| rest | body (may be empty) |

The header always has a `"type"`. Unknown types are ignored; unknown fields are ignored.

| type | Fields | Body |
| --- | --- | --- |
| `hello` | `name` (device name), `platform` (`"macos"` or `"android"`), `version` (1) | none |
| `clip` | `id` (UUID string), `kind` (`"text"`, `"image"` or `"file"`), `mime`, `name` (file name; files only, optional for images), `size` (body length) | the item |
| `ack` | `id` of the clip received | none |
| `ping` | — | none |
| `pong` | — | none |
| `unpair` | — | none |

- The first frame in each direction must be `hello`. The server sends its `hello` only after the
  client's `hello` decrypted.
- `text` bodies are UTF-8 with `mime` `text/plain`. `image` bodies are PNG or JPEG with the
  matching `mime`. `file` bodies are the raw file.
- A receiver sends `ack` after it has stored a clip. It remembers the last 64 clip IDs and drops a
  repeated ID silently (still acking it).
- Send `ping` after 15 s without sending anything on TCP, 25 s on Bluetooth. Answer `ping` with
  `pong`. Close the connection after 60 s without receiving anything.
- On `unpair`, forget the other device and close.
- Maximum clip body: 200 MiB on TCP, 1 MiB on Bluetooth. A clip too large for the current transport
  is queued and sent when a TCP session opens.

## 6. Wi-Fi transport

- The Mac listens on TCP port **47321** (or any free port if taken) and advertises Bonjour service
  type `_frogcompanion._tcp` with TXT record `id=<mac uuid>`.
- The phone tries, in order: the hosts from the last successful connection and the QR code, then
  hosts found through Bonjour (NSD) whose TXT `id` matches. Connect timeout 3 s.

## 7. Bluetooth LE transport

- The Mac is the peripheral. It advertises service `F0C00001-2A32-4AC4-AF29-8824B655BF6F`.
- Characteristics in that service:
  - `F0C00002-2A32-4AC4-AF29-8824B655BF6F` **rx**: the phone writes (write with response).
  - `F0C00003-2A32-4AC4-AF29-8824B655BF6F` **tx**: the Mac notifies; the phone subscribes.
- The characteristics carry the same byte stream as TCP (handshake, then frames), cut into chunks
  of any size up to the current limit: the phone requests MTU 517 and writes chunks of
  `min(MTU - 3, 512)` (an ATT value is at most 512 bytes); the Mac notifies chunks of
  `min(central.maximumUpdateValueLength, 512)`. Chunk boundaries mean nothing.
- The pairing QR's `n` is RFC 3986 percent-encoded (`%20` for a space; `+` is a literal plus).
  UUIDs are parsed case-insensitively and written lowercase.
- The stream starts when the phone has subscribed to tx and writes its handshake. A new
  subscription resets the stream on the Mac. One phone at a time over Bluetooth.
- The phone uses Bluetooth only when no TCP connection works, and retries TCP every 30 s while on
  Bluetooth; when TCP succeeds, it drops the Bluetooth link.

## 8. Clipboard rules

- **Mac → phone**: Frog's clipboard watcher hands each new copy to the Phone feature, which sends
  text and images automatically (setting, on by default). It skips items marked
  `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType` or
  `org.nspasteboard.AutoGeneratedType`, anything Frog's secret detection flags, and changes it
  made itself. Files copied in Finder are sent only when the user chooses to, one `file` clip
  per file.
- **Phone → Mac**: Android does not let background apps read the clipboard, so the phone sends on
  a tap: a notification action, a Quick Settings tile, or the share sheet.
- **Receiving**: text and images go onto the clipboard. Files are saved to Downloads.
