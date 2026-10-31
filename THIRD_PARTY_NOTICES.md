# Third-party components

This repository contains first-party Fala source extracted and adapted by its
author. It does not distribute model weights or Apple SDK binaries.

- [WhisperKit 1.1.1](https://github.com/argmaxinc/WhisperKit/tree/v1.1.1):
  MIT-licensed upstream dependency, resolved by Xcode for the Mac app.
  Preserve its license and notices when distributing binaries.
- [WhisperKit Core ML models](https://huggingface.co/argmaxinc/whisperkit-coreml):
  downloaded at runtime by WhisperKit. Consult the model repository for its
  license and upstream model notices.
- [OpenAI Whisper](https://github.com/openai/whisper): original model family.
- Apple Foundation, Network, CryptoKit, AVFoundation, AppKit and SwiftUI are
  system frameworks governed by Apple's applicable SDK and platform terms.

The MIT license in this repository applies to this repository's source, not a
replacement license for these third-party components.
