# WHDC IPC Protocol (Standard)

This document is the canonical protocol specification for IPC between the **bridge addon** and **companion addons**.

## 1) Scope

- **Authenticated core format**: shared across all transports.
- **Transports**:
  - SuperWoW file IPC transport between bot and bridge (`SWControlIn.txt` / `SWControlOut.txt`)
  - In-game sync-channel chat transport for bridge->companion (`SendChatMessage` / `CHAT_MSG_CHANNEL`)
- **Trust model**: shared-secret signature using configured `password`.

## 2) Protocol version

Current protocol baseline in this repository is **WHDC V1.0**.

## 3) Transport identifiers

### File IPC transport (bot <-> bridge)

Used by current bridge/bot integration over `SWControlIn.txt` and `SWControlOut.txt`.

- Message body: timestamped envelope (see below)

### In-game sync-channel transport (bridge <-> companion)

Companion traffic is carried over one configured sync channel only:

- join: `JoinChannelByName(channel_name, channel_pass)`
- resolve ID: `id = GetChannelName(channel_name)`
- send: `SendChatMessage(message, "CHANNEL", nil, id)`

Channel destination is fixed to configured `channel_name`; it is not selected dynamically from incoming payload fields.

## 4) Envelope formats

Both transports use the same authenticated core:

- `base = cmd|nonce|payload`
- `sig = cheap_sig(base, password)`

### Envelope A (unsuffixed core frame)

`cmd|nonce|payload|sig`

### Envelope B (file IPC compatibility)

`ts|cmd|nonce|payload|sig`

Where `ts` is sender-defined informational timestamp (for example `YYYY-MM-DD HH:MM:SS`) and is **not** included in the signature.

## 5) Field rules

- `cmd`: non-empty token, must not contain `|`
- `nonce`: non-empty token, must not contain `|`
- `payload`: may be empty, may contain `|`
- `sig`: decimal integer string

Nonce requirements:

- Sender MUST make nonce unique over a short replay window.
- Monotonic integer nonces are allowed.
- Random/hash nonces are allowed.

Parser requirements:

- Parser MUST treat the final field as `sig`.
- For Envelope B, parser MUST treat first field as `ts`, then parse `cmd`, `nonce`, and reconstruct `payload` from remaining fields before `sig`.
- Empty payload MUST be accepted.

## 6) Signature algorithm (WHDC V1.0)

`sig = sum(bytes((cmd|nonce|payload) + "|" + password)) mod 65535`

Serialization and verification:

- Signature is serialized as base-10 string.
- Receiver computes expected signature and compares numerically/string-equivalent.

## 7) Command namespace (baseline)

Current interoperable baseline command set:

- `PING` (peer -> bridge)
- `PONG` (bridge -> peer)
- `GUILD` (peer -> bridge)
- `GUILD_ACK` (bridge -> peer)
- `GONLINE` (peer -> bridge)
- `ONLINE` (bridge -> peer)
- `RELOAD` (peer -> bridge)
- `CHANNEL` (peer -> bridge; send to preconfigured sync channel)
- `CHANNEL_ACK` (bridge -> peer; payload `OK` or `FAIL`)

Additional commands MAY be introduced, but names and payload schemas MUST be documented by both sides before use.

## 8) Payload conventions (baseline)

- `GUILD`: payload is full in-game line (commonly `[Name]: message`)
- `GUILD_ACK`: payload `OK` or `FAIL`
- `GONLINE`: empty payload
- `ONLINE`: comma-delimited entries of `name;level;class` (level/class may be empty)
- `PING`: sender-defined payload (commonly unix timestamp)
- `PONG`: responder identity (commonly player name)
- `RELOAD`: empty payload
- `CHANNEL`: payload text to send; destination is always the preconfigured sync channel
- `CHANNEL_ACK`: payload `OK` or `FAIL` (may be delayed when queued/rate-limited)

## 9) Sync-channel join/send standardization

For `CHANNEL` command handling, implementations MUST use the configured sync channel only:

1. Join channel using configured values:
   - `JoinChannelByName(channel_name, channel_pass)`
2. Resolve channel ID from configured channel name:
   - `id = GetChannelName(channel_name)`
3. Send channel message using resolved channel ID:
   - `SendChatMessage(message, "CHANNEL", nil, id)`
4. Apply outbound rate limiting to avoid chat mute (bridge baseline: queued send, minimum interval between channel sends; bridge default `1.0s`).

The destination channel MUST NOT be selected from the incoming payload.
`GetChannelName(channel_name)` resolves runtime channel ID and MUST NOT be treated as a config rewrite.

## 10) Rejection behavior

Reject frame when:

- Envelope parsing fails
- Required fields are missing/empty (`cmd`, `nonce`, `sig`)
- `sig` is non-numeric
- Signature mismatch

Implementations SHOULD log rejection reason for diagnostics.

## 11) Replay guidance

To reduce trivial replay:

- Maintain short LRU/cache of recently accepted `(cmd, nonce, payload, sig)` tuples per sender/context.
- Drop duplicates within a bounded replay window (recommended 60-300s).

## 12) Compatibility contract

Peers are interoperable only if all match:

1. Transport profile and envelope parsing
2. Configured sync channel (`channel_name` + `channel_pass`) for in-game channel transport
3. Field order and delimiter (`|`)
4. Signature algorithm (`WHDC V1.0`) and modulo `65535`
5. Shared password
6. Command names and payload schema

## 13) Test vectors (WHDC V1.0)

Password: `change-me`

### Vector A

- `cmd=test`
- `nonce=1`
- `payload=ok=true`
- core: `test|1|ok=true|change-me`
- expected `sig=2465`
- Envelope A: `test|1|ok=true|2465`

### Vector B

- `cmd=request_import`
- `nonce=42`
- `payload=rotation`
- core: `request_import|42|rotation|change-me`
- expected `sig=3762`
- Envelope A: `request_import|42|rotation|3762`

> Note: `test` and `request_import` are valid as extension commands when both peers explicitly support them.

