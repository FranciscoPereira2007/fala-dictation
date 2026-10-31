# Dictation protocol (Fala v2 subset)

The open receiver listens on TCP 47831 and advertises `_falacore._tcp`.
Each connection carries one request and one reply. All integers are big-endian
unless specified otherwise. This shares the original Fala v2 crypto construction,
but the open receiver deliberately accepts only ping and transcription commands.

## Key and envelope

Generate a random 26-character code from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`.
Normalize the code to uppercase. Derive a 32-byte key with HKDF-SHA256:

- input key material: UTF-8 code
- salt: UTF-8 `fala-link-v2`
- info: UTF-8 `iphone-mac`

The frame is `F2` (two ASCII bytes), a UInt32 ciphertext-envelope length, then
ChaCha20-Poly1305's combined representation: 12-byte random nonce, ciphertext,
16-byte authentication tag. Maximum envelope size is 4 MiB; invalid or incomplete
frames are rejected. No extra authenticated data is supplied.

Request plaintext is a random 16-byte request ID, Int64 Unix milliseconds, then
the body. Reply plaintext is the same 16-byte request ID followed by the reply
body, encrypted with a fresh nonce. The client must verify the reply ID.

## Bodies

| Request | Meaning | Reply |
|---|---|---|
| `P` | Ping | `P` + UTF-8 receiver label |
| `a0R` + PCM | Transcribe | `T` + UTF-8 transcript |

PCM is signed Int16 little-endian, mono, 16 kHz. Maximum recording length is
120 seconds. Empty/odd-length audio and unknown prefixes are rejected. The
receiver does not accept remote text, paste instructions, Enter or shell commands.
Pasting is a receiver-side, session-only preference.

Errors use `E` + UTF-8 message; `B` means the identical request is still pending.
Requests whose timestamp differs by more than 120 seconds are rejected.
Duplicate IDs within the replay window return the original cached reply or `B`,
without running transcription/paste twice. Replay state is memory-only and bounded.
The phone currently performs no automatic retry.
