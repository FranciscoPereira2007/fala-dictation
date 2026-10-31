# Security

Pairing codes are bearer secrets. Anyone with the code and network access can
send audio to the receiver; if paste is enabled, its transcript may be pasted
into the active application. Never paste untrusted dictation into a terminal.
Rotate the code to revoke a paired client. There is no per-device authorization.

Requests and responses use ChaCha20-Poly1305 with a key derived from a random
26-character code using HKDF-SHA256. Requests bind an ID, timestamp and body;
responses bind the request ID. The receiver rejects stale requests, unencrypted
traffic, unsupported commands and oversized frames. Cached replies make a
repeated ID idempotent within the in-memory replay window. State does not survive
a receiver restart. A response cache is bounded to 256 entries.

The listener is reachable on local interfaces, TCP 47831. Do not forward this
port on a router or expose it to the public internet. This is not a multi-user
service or a substitute for a hardened transcription server. A local-network
attacker can still attempt denial of service; at most four connections and one
transcription are accepted concurrently. Authentication does not hide traffic
sizes or timing.

The protocol has not had an external cryptographic audit. Temporary audio files
are removed using normal filesystem deletion, not secure erasure. OS caches,
clipboard history and backups are outside this application's guarantees.

Report suspected vulnerabilities through the repository's private GitHub
vulnerability reporting feature when available; otherwise open an issue asking
for a private contact, without publishing exploit details or secrets.
