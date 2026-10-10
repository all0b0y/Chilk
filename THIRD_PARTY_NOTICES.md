# Third-party notices

Chilk includes the third-party software listed below. Each component is distributed under its own license, reproduced
here; those licenses apply to that component only. Chilk itself is licensed under the Apache License 2.0 (see
[LICENSE](LICENSE) and [NOTICE](NOTICE)).

## libfvad — WebRTC voice activity detection

- Source: <https://github.com/dpirch/libfvad>, v1.0 (commit `99fd86bbb8093a8d0433db3da1d8959c1682adcc`), vendored
  unmodified in `ChilkKit/Sources/CFvad`.
- License: BSD 3-Clause, plus Google's additional patent grant for the WebRTC code (`ChilkKit/Sources/CFvad/PATENTS`).

```
Copyright (c) 2011, The WebRTC project authors. All rights reserved.
Copyright (c) 2016 Daniel Pirch

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## WhisperKit (Argmax OSS) 1.1.0

- Source: <https://github.com/argmaxinc/WhisperKit>, linked statically through Swift Package Manager.
- License: MIT.

```
MIT License

Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### swift-transformers (portions of WhisperKit)

- Source: <https://github.com/huggingface/swift-transformers>. Portions of WhisperKit (`Sources/ArgmaxCore/External`)
  are derived from it and were modified by Argmax, Inc.
- Copyright 2022 Hugging Face SAS. Licensed under the Apache License, Version 2.0; the full text of that license is in
  [LICENSE](LICENSE).

## Speech model downloaded on first use (not included in Chilk)

When you turn Chilk's ears on, it downloads the Core ML conversion of OpenAI Whisper large-v3 turbo
(`openai_whisper-large-v3-v20240930_turbo` from <https://huggingface.co/argmaxinc/whisperkit-coreml>) to listen for its
name on your Mac. The model is not part of Chilk's download; it is published under the MIT License by its authors
(OpenAI Whisper and Argmax).
