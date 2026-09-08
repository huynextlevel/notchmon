# Third-party code

- `Sources/NotchMon/UI/GlyphOutline.swift` — brand-mark outlines from
  [codenotch](https://github.com/vinzdg/codenotch), MIT License,
  Copyright (c) 2026 Vinz.
- `Sources/NotchMon/Usage/QuotaTrend.swift` — the pace fold and its three
  empirical constants are ported from
  [TokenBar](https://github.com/Nanako0129/TokenBar)'s `QuotaTrend` /
  `QuotaTrendFold`, MIT License. `QuotaDurationSource` follows the same
  project's `DurationSource`.
- `vendor/` — the [tokscale](https://github.com/junhoyeo/tokscale) CLI, MIT
  License, fetched at build time and spawned as a subprocess. A released build
  **redistributes this binary inside the app bundle**, which the MIT licence
  permits and which obliges the notice above to travel with it — so this file
  ships in the repository and the licence text below is reproduced in full.

---

## MIT License

Applies to codenotch, TokenBar and tokscale, each under its own copyright.

```
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
