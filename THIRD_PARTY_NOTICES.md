# Third-party notices and protocol references

## Robot club / chrisns/meccanoid

The Swift packet encoders and controller design were informed by, and adapted from, the open-source work of Chris Nesbitt-Smith. The native UI and CoreBluetooth implementation are maintained in this repository.

Pinned reference: [`chrisns/meccanoid`, commit `929ab37efee7b2615e71dadd1589eaf53e72dcb1`](https://github.com/chrisns/meccanoid/tree/929ab37efee7b2615e71dadd1589eaf53e72dcb1).

Relevant sources:

- [Packet encoding](https://github.com/chrisns/meccanoid/blob/929ab37efee7b2615e71dadd1589eaf53e72dcb1/src/protocol.js)
- [Connection and control](https://github.com/chrisns/meccanoid/blob/929ab37efee7b2615e71dadd1589eaf53e72dcb1/src/meccanoid.js)
- [Protocol research](https://github.com/chrisns/meccanoid/blob/929ab37efee7b2615e71dadd1589eaf53e72dcb1/docs/protocol.md)
- [Original MIT licence](https://github.com/chrisns/meccanoid/blob/929ab37efee7b2615e71dadd1589eaf53e72dcb1/LICENSE)

The original copyright and permission notice follows in full:

```text
MIT License

Copyright (c) 2026 Chris Nesbitt-Smith

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

The upstream project includes other browser libraries, fonts and models. None of those assets or dependencies are bundled here.

## Historical protocol reference: pymecca

[`iamsrp/pymecca`](https://github.com/iamsrp/pymecca), particularly [`meccanoid.py`](https://github.com/iamsrp/pymecca/blob/master/meccanoid.py), is an earlier Apache-2.0 implementation and a reference for the documented Bluetooth wire format. This repository does not distribute pymecca code. Its command values and framing are treated as protocol facts, implemented in Swift and attributed here.

## Original manufacturer software

Independent static inspection of the original Android application helped corroborate wire-format facts. No APK, decompiled assembly or source, firmware, voice recording, vendor logo or other vendor asset is redistributed. This repository does not download those files at build time or runtime.

Meccano, MeccaBrain and Meccanoid names identify compatible hardware and belong to their respective owners. This project is not endorsed by the manufacturer. Third-party hardware reports establish only the observations reported on those systems, not verification of this Swift app.
