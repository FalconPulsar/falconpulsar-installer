# Releasing

How to cut a release of the FalconPulsar Installer. Read this end-to-end
before tagging your first release; the macOS signing path has a lot of
moving parts and the failure modes (shipping an unsigned DMG, leaking a
private key into logs, expired cert) are each a separate headache.

## Audience

Project maintainers with push access to `main` and permission to push
tags. Contributors reading this for context — you don't need any of these
secrets to build locally; `./macos/build-dmg.sh` with no env vars
produces an ad-hoc-signed DMG that's fine for testing.

---

## 1. Overview of the release pipeline

A `v*` tag pushed to `main` triggers `.github/workflows/release.yml`,
which does four things in parallel then publishes:

    ┌──────────────────────────┐  ┌──────────────────────────┐
    │ bundle                   │  │ build-windows-exe        │
    │ (ubuntu-latest)          │  │ (windows-latest)         │
    │  - install-linux.sh      │  │  - fp-windows-amd64.exe  │
    │  - uninstall-linux.sh    │  │  - fp-linux-amd64        │
    │  - install-macos.sh      │  │  - FalconPulsar-Setup.exe│
    │  - linux.sh (bootstrap)  │  │    (Inno Setup, unsigned)│
    └──────────┬───────────────┘  └───────────┬──────────────┘
               │                              │
    ┌──────────┴──────────────────────────────┴──────────────┐
    │ build-macos-dmg (macos-latest)                         │
    │  - import Developer ID cert into ephemeral keychain    │
    │  - write .p8 API key to $RUNNER_TEMP                   │
    │  - FP_SIGN=1 ./macos/build-dmg.sh                      │
    │    → Hardened Runtime codesign                         │
    │    → notarytool submit + wait                          │
    │    → stapler staple                                    │
    │    → spctl assess (sanity check)                       │
    │  - cleanup keychain + p8 (always: true)                │
    └────────────────────────┬───────────────────────────────┘
                             │
                    ┌────────┴────────┐
                    │ publish         │
                    │ (ubuntu-latest) │
                    │  - SHA-256 sums │
                    │  - gh release   │
                    └─────────────────┘

Windows signing is **not** wired up yet. The current Inno Setup output
is unsigned; users see a SmartScreen warning. That's a separate future
item — covered at the end of this doc.

---

## 2. macOS signing: the six secrets

The `build-macos-dmg` job in `release.yml` requires six repository
secrets. All are set under
**Settings → Secrets and variables → Actions → New repository secret**.

| Secret name                              | What it is                                                              |
|------------------------------------------|-------------------------------------------------------------------------|
| `APPLE_DEV_ID_APPLICATION_P12_BASE64`    | base64 of your Developer ID Application `.p12` export (cert + key)      |
| `APPLE_DEV_ID_APPLICATION_P12_PASSWORD`  | password set when exporting the `.p12` from Keychain Access             |
| `APPLE_SIGNING_IDENTITY`                 | full cert CN, e.g. `Developer ID Application: Jane Doe (ABCD1234)`      |
| `APPLE_NOTARY_KEY_ID`                    | App Store Connect API Key ID (10 chars)                                 |
| `APPLE_NOTARY_ISSUER_ID`                 | issuer UUID from App Store Connect                                      |
| `APPLE_NOTARY_KEY_P8_BASE64`             | base64 of your `.p8` private key from App Store Connect                 |

The CI step `: "${VAR:?...}"` guards will hard-fail the build if any
secret is missing or empty — there is no silent fallback to ad-hoc. A
tag push that fails secret validation produces no release artifacts
until you fix the secret and re-tag.

### A note on unused secrets

You may also see `APPLE_TEAM_ID` in the repository secrets if you added
it following an older setup guide. It's **not used** by the current
signing flow — the Team ID is already encoded in both the signing-
identity CN and the notary-key binding, so we never need it separately.
It's harmless to leave in place; we might use it later if we grow a
`notarytool --team-id` code path (e.g. for multi-team accounts).

### 2a. Generating the .p12

1. **Apple Developer portal → Certificates** → create a "Developer ID
   Application" cert from a CSR generated in Keychain Access.
2. Download the `.cer`, double-click to import into the login keychain.
3. Install the intermediate cert from
   <https://www.apple.com/certificateauthority/> (Developer ID - G2) so
   Keychain Access shows it as trusted.
4. In Keychain Access, right-click the cert → **Export** →
   `FalconPulsar-DevID.p12`. Set a strong password.
5. Base64-encode and stuff into the secret:

       base64 -i FalconPulsar-DevID.p12 | pbcopy
       # paste into APPLE_DEV_ID_APPLICATION_P12_BASE64
       # put the .p12 export password into APPLE_DEV_ID_APPLICATION_P12_PASSWORD

6. For `APPLE_SIGNING_IDENTITY`, copy the exact CN:

       security find-identity -v -p codesigning login.keychain
       # → "Developer ID Application: YOUR NAME OR TEAM (XXXXXXXXXX)"

### 2b. Generating the App Store Connect API key

Notarization is done via **notarytool** using an API key, not Apple ID
+ app-specific password. The API-key flow is stable under MFA and
doesn't break when Apple rotates session tokens.

1. App Store Connect → **Users and Access** → **Integrations** →
   **App Store Connect API** → **Team Keys**.
2. If "Request Access" appears, click it and accept the terms once
   (Account Holder only).
3. **Generate API Key**. Role: **Developer** (this is the minimum
   role that can submit notarizations; do NOT use Admin).
4. Download the `.p8` file **immediately** — Apple only lets you
   download it once. If you lose it, revoke the key and make a new one.
5. From the same page, copy:
   - **Key ID** → `APPLE_NOTARY_KEY_ID`
   - **Issuer ID** (at the top of the page, team-level) → `APPLE_NOTARY_ISSUER_ID`
6. Base64 the .p8:

       base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
       # paste into APPLE_NOTARY_KEY_P8_BASE64

### 2c. After secrets are in place

Nothing else to configure. The next `v*` tag push triggers the signed
build automatically.

---

## 3. Cutting a release

1. Bump the version. The single source of truth is the `VERSION` file at
   the repo root; every remaining hardcoded site (the Go `Version` var in
   `console/internal/cli/cli.go`, the Go backup-manifest
   `falconpulsar_version` key in `console/internal/configbackup/backup.go`,
   and the `installer.iss` `#define MyAppVersion`) is rewritten by
   `scripts/sync-version.sh`. The macOS menu-bar app and the Windows tray
   app (menu headers and backup manifests) take their version from
   build-time stamping (`CFBundleShortVersionString` / assembly version),
   so they need no rewrite. To bump:

       echo 0.2.0 > VERSION
       scripts/sync-version.sh
       git add VERSION console windows
       git commit -m "Release v0.2.0"

   `scripts/sync-version.sh --check` is also wired up for CI — it exits
   non-zero if any site has drifted from `VERSION`, so a stale hardcoded
   string can never sneak into a release.

   Other version references that are *not* code (README badges, install
   URLs in docs) still need a manual sweep — those tend to be marketing
   copy that doesn't follow the same template.

2. Verify the build works locally with an ad-hoc signature:

       ./macos/build-dmg.sh
       # → dist/FalconPulsar-Setup.dmg (ad-hoc, Gatekeeper warns on download)

   Mount and smoke-test. This does NOT test notarization — that only
   runs in CI.

3. Tag and push:

       git tag -a v0.1.0 -m "v0.1.0"
       git push origin v0.1.0

4. Watch the workflow at
   `https://github.com/FalconPulsar/falconpulsar-installer/actions`.
   Expected timings:
   - `bundle`: ~30s
   - `build-windows-exe`: ~3 min
   - `build-macos-dmg`: **6–12 min** (most of this is Apple's notary
     service; don't cancel just because it sits at "submitted" for a
     while).
   - `publish`: ~30s after all above complete.

5. Verify the published release at
   `https://github.com/FalconPulsar/falconpulsar-installer/releases/tag/v0.1.0`:
   - Download `FalconPulsar-Setup.dmg` in Safari
   - Double-click → should open with NO "unidentified developer" prompt
   - Right-click the DMG → Get Info → under "General" it should say
     "Signed by Developer ID Application: ..." and the icon should have
     a small checkmark
   - In Terminal:

         xcrun stapler validate ~/Downloads/FalconPulsar-Setup.dmg
         # → "The validate action worked!"

         spctl --assess --type open \
               --context context:primary-signature \
               --verbose=2 ~/Downloads/FalconPulsar-Setup.dmg
         # → "source=Notarized Developer ID"

   If either command fails, something went wrong in notarization — the
   tag is still published but the DMG is broken. Delete the release,
   delete the tag (`git push --delete origin v0.1.0`), fix the issue,
   re-tag.

---

## 4. Local signed builds (optional)

You can run the signed pipeline on your own Mac without touching CI. This
is the fastest way to debug a signing issue — CI adds 10+ min feedback
loops.

    # 1. Make sure your Developer ID cert is in your login keychain and
    #    the private key is unlocked.
    security find-identity -v -p codesigning
    # → expect to see "Developer ID Application: ..."

    # 2. Have the .p8 API key at a known path:
    export FP_NOTARY_KEY_P8_PATH=~/secure/AuthKey_XXXXXXXXXX.p8

    # 3. Run the signed build:
    export FP_SIGN=1
    export FP_SIGN_IDENTITY="Developer ID Application: YOUR NAME (ABCD1234)"
    export FP_NOTARY_KEY_ID=XXXXXXXXXX
    export FP_NOTARY_ISSUER_ID=11111111-2222-3333-4444-555555555555
    ./macos/build-dmg.sh

This does the full codesign + notarize + staple. Takes the same 6–12 min
as CI since Apple's notary service is the bottleneck. Artifact lands at
`dist/FalconPulsar-Setup.dmg`.

---

## 5. Troubleshooting

### `errSecInternalComponent` during codesign

The CI keychain isn't unlocked or the partition list isn't set. Check
that `security set-key-partition-list` ran successfully in the "Import
Developer ID signing certificate" step. On a clean CI run this
shouldn't happen; if it does, the `.p12` password is probably wrong.

### `notarization failed` with status "Invalid"

Open the fetched submission log (the script pulls it automatically on
failure). Common reasons:

- **Missing `--options runtime`** on some nested binary. `build-dmg.sh`
  signs the embedded `fp` binary separately — if you've added a new
  nested executable (e.g. a helper tool in `Contents/Resources/`), add
  a `sign_binary` call before the bundle sign.
- **The signing identity isn't a Developer ID Application cert** —
  Mac App Store ("3rd Party Mac Developer") certs can't notarize.
  Verify with `security find-identity`.
- **Team ID mismatch** between cert and API key. Both must belong to
  the same Apple Developer team.

### `stapler: could not find the ticket for your app`

Usually means notarization succeeded but you tried to staple the wrong
file, or Apple's CDN hasn't propagated the ticket yet (rare, retry
after 1 min). The build-dmg.sh staples the DMG, which is the right
target — if this fires in CI, re-run the release job.

### Cert expires or gets revoked

Developer ID Application certs last 5 years. 60 days before expiry
Apple emails the Account Holder. To rotate:

1. Generate a new CSR in Keychain Access.
2. Create a new Developer ID Application cert on the Apple portal
   (you can have up to 5 active).
3. Export a new `.p12`, update `APPLE_DEV_ID_APPLICATION_P12_BASE64` /
   `APPLE_DEV_ID_APPLICATION_P12_PASSWORD` / `APPLE_SIGNING_IDENTITY`
   secrets.
4. Leave the old cert installed until after the next successful
   signed release — lets you roll back by reverting secrets.
5. Once the new release is verified, revoke the old cert on the
   portal.

Already-shipped DMGs keep working after revocation because the
stapled ticket captures Apple's trust at notarization time.

### Lost the `.p8` notary key

Apple only lets you download the .p8 once. If you lose it:

1. App Store Connect → Users and Access → Integrations → Team Keys.
2. Revoke the lost key.
3. Generate a new one (Developer role).
4. Update `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_KEY_P8_BASE64` secrets.

---

## 6. What's NOT signed yet

- **Windows installer (`FalconPulsar-Setup.exe`)**: unsigned.
  SmartScreen shows "Unrecognized app" on first launch. Fixing this
  needs an OV or EV code-signing cert from DigiCert / SSL.com / Sectigo
  (~$300–700/yr for OV, ~$400–900/yr for EV). When we add it,
  `release.yml`'s `build-windows-exe` job gains a signtool step against
  `FalconPulsar-Setup.exe` after Inno Setup emits it. Secrets needed:
  `WINDOWS_CERT_PFX_BASE64`, `WINDOWS_CERT_PASSWORD`.

- **Standalone `fp-macos-*` binaries from `build-fp.yml`**: these are
  CI-only artifacts with 30-day retention, not attached to releases —
  so they're never downloaded by end users and don't need to be
  Gatekeeper-clean. The `fp` binary that *ships* (inside the DMG) is
  signed + notarized as part of the DMG pipeline.

---

## 7. Security hygiene

- **Never commit a `.p12` or `.p8` file** — `.gitignore` doesn't cover
  them by extension because they can be named anything.
- **Don't base64-decode secrets into shared locations** like `~/Desktop`
  during troubleshooting. `$RUNNER_TEMP` (CI) and `/tmp` (local) are
  ephemeral; keep keys there.
- **There is no keychain-password secret to rotate.** The ephemeral
  build keychain is unlocked with a random password generated inline
  by `openssl rand` and never leaves the job's memory.
- **The `.p8` API key has full submit rights** for any binary under the
  team's notary queue. If it leaks, revoke it immediately via App Store
  Connect and regenerate. Notarizations that already completed are
  unaffected.
