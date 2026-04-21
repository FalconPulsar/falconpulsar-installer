# Security Policy

The FalconPulsar team takes security seriously. If you believe you have found a
security vulnerability in this installer or in any FalconPulsar component, please
report it to us privately — **do not open a public GitHub issue**.

## Reporting a vulnerability

Email **security@falconpulsar.com**. Include:

- A description of the vulnerability and the component affected
- Steps to reproduce (proof-of-concept code is welcome)
- The version / commit SHA you tested against
- Your assessment of the impact (what an attacker could achieve)
- Any suggested mitigation, if you have one

We will acknowledge receipt within **3 business days** and aim to provide an
initial assessment within **7 business days**. If the report is accepted, we
will coordinate a disclosure timeline with you before any public announcement.

We support responsible disclosure and will credit reporters in the release notes
(unless you prefer to remain anonymous).

## Supported versions

FalconPulsar is currently in pre-release (v0.x). Security fixes are applied to
the latest tagged release only. Once v1.0 ships, this table will be updated to
reflect which versions receive backported fixes.

| Version | Supported |
|---|---|
| Latest `v0.x` | ✅ |
| Older `v0.x` | ❌ |

## Scope

This policy covers:

- The installer scripts and source in this repository
  (`linux/`, `macos/`, `windows/`, `shared/`)
- The `fp` CLI and tray / menu-bar / GUI apps shipped with the installers
  (`console/`, `windows/tray-app/`, `windows/fp-wrapper/`,
  `macos/menu-bar-app/`, `macos/installer-app/`)
- The release-asset auth-proxy Cloudflare Worker (`infra/cloudflare/`)
- The compiled installer artifacts published to GitHub Releases
- The build pipeline that produces those artifacts

For vulnerabilities in FalconPulsar Core, UI, or AI Gateway, please use the same
contact address — we triage all FalconPulsar security reports centrally.

## Out of scope

- Vulnerabilities in third-party software the installer uses (Docker Engine,
  WSL2, the Linux kernel, etc.). Report those to the respective upstream
  projects.
- Social engineering, physical access attacks, or issues requiring the victim
  to run an already-compromised binary.
- Missing security headers on marketing sites unrelated to the installer.

## Safe harbour

Good-faith security research conducted within the scope of this policy will not
result in legal action. We ask that you:

- Give us reasonable time to investigate and remediate before any public
  disclosure
- Avoid privacy violations, destruction of data, or interruption of service
- Only test against systems you own or have explicit permission to test
