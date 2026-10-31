# Fala Dictation

This repository is the standalone, open-source dictation subset of Fala.
Do not add production accounts, relays, signing credentials, private transcripts,
screen control, shell execution or commercial application modules.

Run `swift test` for the protocol suite. Generate Xcode projects with
`xcodegen generate`; never commit signing teams or personal provisioning profiles.
Build both application targets after changing shared sources.

Keep audio decoding, normalization and inference off the main thread. Bound
network frame sizes, concurrent requests and replay state. Paste is opt-in,
session-only, and must never automatically send Enter. Reject cleartext v1.
After async inference, verify request liveness and pairing generation before
updating the UI or pasting. Never persist transcript text in diagnostics.

Hardware validation must be reported separately from builds and loopback tests.
Do not claim real-world adoption, medical accessibility benefits, measured
latency or successful phone-to-Mac validation without evidence.
