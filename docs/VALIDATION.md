# Validation of the initial developer release

Validated on 2026-10-31:

- `swift test`: 10 tests, zero failures. Includes authenticated loopback TCP
  round trips against the actual receiver, replayed request IDs returning cached
  transcripts without repeating delivery, revocation of in-flight requests when
  the receiver stops, rejection of remote paste/Enter commands, malformed-frame
  rejection, wrong-key/tamper rejection, bounded replay state and PCM limits.
- Unsigned Debug build of FalaDictationMac for macOS: passed.
- Unsigned Debug build of FalaDictationPhone for iOS Simulator: passed.
- Independent second-model source review of networking and native lifecycle:
  findings addressed; no remaining release blockers reported by inspection.
- Secret scan of the publication file set: passed.
- GitHub Actions protocol tests and both application builds: passed on the
  initial publication. Later commits run the same workflow.
- Local runtime smoke test against the actual Mac app and Whisper base model:
  authenticated ping, encrypted audio upload and encrypted transcript reply
  passed. macOS-generated English speech returned
  `Hello, this is a local dictation test.` No remote transcription API was used.

The protocol integration tests use synthetic samples and a stub transcription
callback. They do not measure Whisper accuracy or microphone behavior.

Not yet validated for this standalone extraction: recording and sending from a
physical iPhone, end-to-end paste into other applications, permission recovery,
sleep/wake and installation by an independent user. These need real-device
testing; build success is not a substitute.

No external adoption, latency benchmark or external cryptographic audit is claimed.
