# Security Policy

FalconPulsar is an open-source project. We take security seriously and
aim to fix vulnerabilities quickly once they are responsibly reported.
If you believe you have found a security vulnerability in this installer
or in any FalconPulsar component, please report it to us privately —
**do not open a public GitHub issue**.

## Reporting a vulnerability

### Preferred channel — GitHub Private Vulnerability Reporting

Submit a private advisory at:

**https://github.com/FalconPulsar/falconpulsar-installer/security/advisories/new**

This creates a private thread visible only to the reporter and the
project maintainers. It lets us collaborate on the fix, track a CVE
identifier, and publish a coordinated advisory when the fix ships.

### Alternative — email

If GitHub Private Vulnerability Reporting is not an option for you
(no GitHub account, corporate firewall, or you need to attach an
encrypted payload), email:

**security@falconpulsar.com**

For encrypted reports, see the [PGP key](#pgp-key) section below.

### What to include

- A description of the vulnerability and the component affected
- Steps to reproduce (proof-of-concept code is welcome)
- The version / commit SHA you tested against
- Your assessment of the impact (what an attacker could achieve)
- Any suggested mitigation, if you have one

## What happens after you report

FalconPulsar is a small open-source project maintained on a best-effort
basis. We do not have a dedicated security team; reports go directly to
the maintainers and are handled as quickly as we reasonably can.

- **Acknowledgement:** within **5 business days** of receipt.
- **Initial assessment:** typically within 1–2 weeks, depending on the
  severity of the report and the complexity of the component involved.
  If triage takes longer, we will keep you updated.
- **Fix and disclosure:** once a fix is developed, we coordinate a
  disclosure timeline with you. For straightforward issues we typically
  ship the fix first and publish the advisory shortly after release.
  For issues requiring broader coordination (affected downstream
  distributors, supply-chain impact), we work with you on a disclosure
  window before any public announcement.

We support responsible disclosure and will credit reporters in the
published advisory and in the release notes, unless you prefer to remain
anonymous.

## Scope

This policy covers:

- The installer scripts and source in this repository
  (`linux/`, `macos/`, `windows/`, `shared/`)
- The `fp` CLI and tray / menu-bar / GUI apps shipped with the installers
  (`console/`, `windows/tray-app/`, `windows/fp-wrapper/`,
  `macos/menu-bar-app/`, `macos/installer-app/`)
- The compiled installer artifacts published to GitHub Releases
- The build pipeline that produces those artifacts
  (`.github/workflows/`, `.github/scripts/bundle.sh`)

For vulnerabilities in other FalconPulsar components (Core, Web UI,
AI Gateway), please also use the channels above. Reports land in the
same place and are routed to the correct maintainers internally.

## Out of scope

- Vulnerabilities in third-party software the installer uses
  (Docker Engine, WSL2, the Linux kernel, Inno Setup, etc.). Please
  report those to the respective upstream projects.
- Social engineering, physical access attacks, or issues that require
  the victim to run an already-compromised binary.
- Missing security headers on marketing sites unrelated to the installer.
- Findings from automated scanners without a concrete exploit path or
  at-risk asset.

## Compromised release artifacts

If you believe a published installer artifact has been tampered with:

1. Compare the SHA-256 of your downloaded file against the sums
   published on the GitHub Release page. Every release includes a
   `SHA256SUMS.txt` asset that lists the canonical hash for every
   artifact in that release.

   ```
   # macOS / Linux
   shasum -a 256 FalconPulsar-Setup.dmg

   # Windows PowerShell
   Get-FileHash .\FalconPulsar-Setup.exe -Algorithm SHA256
   ```

2. If the hash does not match the published `SHA256SUMS.txt`, **stop
   installing immediately** and report to the security channels above
   with:
   - The asset name and version
   - The hash you observed
   - Where you downloaded it from (URL, mirror, CDN edge)

Mismatches are serious — they indicate either a CDN / mirror
compromise or an attack in transit. We will investigate, issue a
replacement release, and revoke any affected signing certificates if
warranted.

## Safe harbour

Good-faith security research conducted within the scope of this policy
will not result in legal action from us. We ask that you:

- Give us reasonable time to investigate and remediate before any
  public disclosure
- Avoid privacy violations, destruction of data, or interruption of
  service
- Only test against systems you own or have explicit permission to test

This is a promise of non-prosecution on our part; it does not grant
immunity from other applicable laws or the terms of third-party services
you interact with during your research.

## Supported versions

FalconPulsar is currently in pre-release (v0.x). Security fixes are
applied to the latest tagged release only. Once v1.0 ships, this table
will be updated to reflect which versions receive backported fixes.

| Version | Supported |
|---|---|
| Latest `v0.x` | ✅ |
| Older `v0.x` | ❌ |

## PGP key

<!--
  Replace the placeholder below with the real public key before
  publishing. Generate one with:

      gpg --quick-generate-key "FalconPulsar Security <security@falconpulsar.com>" default default 2y
      gpg --armor --export security@falconpulsar.com > security-pubkey.asc
      gpg --fingerprint security@falconpulsar.com

  Then paste:
    - the fingerprint into "Fingerprint:" below
    - the ASCII-armored public key into the code block below
    - upload the key to keys.openpgp.org and keyserver.ubuntu.com

  Until then, the PGP section is a stub. Do not ship the repo public
  with the placeholder visible.
-->

For encrypted reports to `security@falconpulsar.com`, use the
FalconPulsar security PGP public key below.

**Fingerprint:** *(not yet published — coming before v1.0)*

Key servers: [keys.openpgp.org](https://keys.openpgp.org) and
[keyserver.ubuntu.com](https://keyserver.ubuntu.com) (once published).

```
-----BEGIN PGP PUBLIC KEY BLOCK-----

(public key will be inserted here before the repo goes public)

-----END PGP PUBLIC KEY BLOCK-----
```

If this section still shows the placeholder when you read it, the key
hasn't been published yet. Use GitHub Private Vulnerability Reporting
(first option above) in the meantime — reports travel over TLS to
GitHub and are visible only to maintainers.
