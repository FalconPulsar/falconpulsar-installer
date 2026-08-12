# Third-Party Notices

FalconPulsar's installer and the `fp` control CLI are licensed under the
GNU Affero General Public License v3.0 (see [LICENSE](LICENSE)).

This project redistributes, in the compiled `fp` binary, the third-party Go
modules listed below. Each is used under its own license, all of which are
permissive and compatible with the AGPL-3.0. This file is generated from the
modules actually linked into the release binary (`go version -m fp`); build- and
test-only transitive dependencies that are not compiled into the shipped binary
are intentionally omitted.

The macOS components (SwiftUI installer, menu-bar tray) and the Windows tray
(C# / WinForms) ship with **no** third-party package dependencies — they use
only the platform SDK frameworks. The Windows installer is built with
[Inno Setup](https://jrsoftware.org/isinfo.php), used under its own license and
not redistributed as a library.

## Go modules linked into the `fp` binary

| Module | Version | License |
|---|---|---|
| github.com/gdamore/encoding | v1.0.1 | Apache-2.0 |
| github.com/gdamore/tcell/v2 | v2.13.10 | Apache-2.0 |
| github.com/inconshreveable/mousetrap (Windows only) | v1.1.0 | Apache-2.0 |
| github.com/lucasb-eyer/go-colorful | v1.3.0 | MIT |
| github.com/rivo/tview | v0.42.0 | MIT |
| github.com/rivo/uniseg | v0.4.7 | MIT |
| github.com/spf13/cobra | v1.10.2 | Apache-2.0 |
| github.com/spf13/pflag | v1.0.9 | BSD-3-Clause |
| golang.org/x/crypto | v0.54.0 | BSD-3-Clause |
| golang.org/x/sys | v0.47.0 | BSD-3-Clause |
| golang.org/x/term | v0.45.0 | BSD-3-Clause |
| golang.org/x/text | v0.40.0 | BSD-3-Clause |
The full text of each license is available in the corresponding module's source
repository and in your local Go module cache
(`$(go env GOMODCACHE)/<module>@<version>/LICENSE`). The Apache-2.0, MIT, and
BSD-3-Clause licenses each require that their copyright notice and permission
notice be retained; this file preserves that attribution.

To regenerate this list after a dependency change:

```
cd console && go build -o /tmp/fp ./cmd/fp && go version -m /tmp/fp | awk '$1=="dep"{print $2, $3}'
```
