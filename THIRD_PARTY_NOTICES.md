# Third-party notices

This file lists the code in this repository that comes from other projects, with its license and where the license text is. The rest of the repository is MIT (see [LICENSE](LICENSE)).

Packages that SwiftPM fetches as dependencies are not copied into this repository and are not listed here. The dependency is [SwiftProtobuf](https://github.com/apple/swift-protobuf) (Apache-2.0).

## Starscream (Apache-2.0)

Four files derive from Starscream version 3 and are modified. The original copyright lines of each file are unchanged, and each file's header has a "Modified by ImpulseM" line below them.

| File | Original copyright |
|---|---|
| `Sources/SwiftCentrifuge/WebSocket/WebSocket.swift` | Copyright (c) 2014-2017 Dalton Cherry |
| `Sources/SwiftCentrifuge/SSLSecurity.swift` | Copyright (c) 2014-2016 Dalton Cherry |
| `Sources/SwiftCentrifuge/SSLClientCertificate.swift` | Copyright © 2018 Vluxe |
| `Sources/SwiftCentrifuge/Compression.swift` | Copyright © 2017 Joseph Ross |

- Source: https://github.com/daltoniam/Starscream, the 3.1.2 tag, from which the files derive.
- License text: [licenses/Apache-2.0.txt](licenses/Apache-2.0.txt), the Apache License, Version 2.0, copied verbatim from https://www.apache.org/licenses/LICENSE-2.0.txt.
- The `LICENSE` file of the Starscream 3.1.2 tag is kept as [licenses/Starscream-LICENSE.txt](licenses/Starscream-LICENSE.txt), copied verbatim from https://github.com/daltoniam/Starscream/blob/3.1.2/LICENSE.
- Starscream has no NOTICE file.
- Changes: these files are modified in this repository, for example in access control and in their integration with the client. The header of each file states the modification. The details are recorded in the git history of this repository.

## Centrifuge protocol (MIT)

- `client.proto` is derived from `definitions/client.proto` of the Protocol repository, https://github.com/centrifugal/protocol (fork: https://github.com/Impulse-m/ImpulseM.Centrifugo.Protocol). It adds fork fields only, numbered 1000 and up (for example `app_code`, `app_type`, `metadata`, `time`, `instance`, `user`, `auth_class`, `headers`, `msg_id`, `ack`, `retransmit`, `after`, `without_updates`, `cancel` and `cached`), and a comment on the fork numbering. The upstream fields and comments are unchanged. `Sources/SwiftCentrifuge/client.pb.swift` is generated from it.
- Copyright (c) 2023 Centrifugal Labs LTD.
- License text: [licenses/MIT-protocol.txt](licenses/MIT-protocol.txt).

## Fossil delta format (BSD-2-Clause)

- `Sources/SwiftCentrifuge/DeltaFossil.swift` is a port of the apply step (`delta_apply`) of the Fossil SCM delta code, `src/delta.c`, with its `getInt` decoder and its checksum. The file header credits the author of the original algorithm, D. Richard Hipp.
- Source: https://fossil-scm.org/home/doc/trunk/src/delta.c. Its header reads "Copyright (c) 2006 D. Richard Hipp" and states that the code is under the Simplified BSD License (2-Clause).
- License text: [licenses/BSD-2-Clause-fossil.txt](licenses/BSD-2-Clause-fossil.txt), copied verbatim from the Fossil SCM license page, https://fossil-scm.org/home/doc/trunk/COPYRIGHT-BSD2.txt (the page is the source of the text; its copyright line reads "Copyright 2007 D. Richard Hipp. All rights reserved.").
- The Swift code was compared with `delta.c` and follows it: the value table, the `getInt` decoder and the checksum follow the C code, so it is a port of `delta.c`, not of another port of the format.
- Changes: the file keeps only the apply step. The changes are recorded in the git history of this repository.
