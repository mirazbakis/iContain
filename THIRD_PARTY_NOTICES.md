# Third-party notices

iContain is MIT-licensed (see LICENSE). Builds include the following software, each under its own license.

| Project | How iContain uses it | License |
|---|---|---|
| [idevice](https://github.com/jkcoxson/idevice) by Jackson Coxson | Tunnel to this device through LocalDevVPN, Developer Disk Image mounting and device-wide location simulation | MIT |
| [isideload](https://github.com/nab138/isideload) by nab138 | Apple ID sign-in, anisette, developer services and certificates | MIT |
| [apple-codesign-quick](https://crates.io/crates/apple-codesign-quick) | Code signing, statically linked into builds. You may modify it and relink iContain with your modified version: build `core/` against it with `scripts/build-rust.sh` | LGPL-2.1-or-later |

Builds also include the Rust crates these depend on, each under its own license (mostly MIT and/or Apache-2.0). Run `cargo license` in `core/` for the full list.

iContain's app loader is its own implementation. It does not include code from LiveContainer, which uses the same publicly documented technique (loading an app's executable as a library inside a host app).

iContain does not include or redistribute LocalDevVPN or Apple's Developer Disk Image. LocalDevVPN is installed separately from the App Store, and the Developer Disk Image is downloaded from [doronz88/DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) the first time device-wide location is used.

---

## idevice (MIT)

```
Copyright 2026 Jackson Coxson

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

---

## isideload (MIT)

```
MIT License

Copyright (c) 2025 nab138

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
