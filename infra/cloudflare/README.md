# get.falconpulsar.com — Cloudflare Worker

A tiny Cloudflare Worker that auth-proxies GitHub release assets so users
can do `curl -fsSL https://get.falconpulsar.com/linux | sudo bash` even
while the repo stays private.

## Why a worker

Before this, the `get.falconpulsar.com/linux` route was a plain 302 to
`github.com/.../releases/latest/download/install-linux.sh`. That 302 is
fine only if the repo is public — GitHub returns 404 on anonymous
requests for private-repo release assets. A Worker can carry a stored
PAT and stream the asset body back to anonymous clients.

## Routes

| Request path | Release asset |
|---|---|
| `/linux` | `linux.sh` (the bootstrap dispatcher) |
| `/linux/install` | `install-linux.sh` |
| `/linux/uninstall` | `uninstall-linux.sh` |
| `/macos` | `install-macos.sh` |
| `/macos/install` | `install-macos.sh` |
| `/macos/uninstall` | `uninstall-macos.sh` (if published) |
| `/windows` | `FalconPulsar-Setup.exe` |
| `/version` | plain-text: the resolved release tag |
| `/` | 200 OK with a short usage hint |

Pins to the **latest** release by default. Set `RELEASE_TAG` in
`wrangler.toml` [vars] to pin a specific tag (useful for staging).

## First-time deploy

1. Install wrangler:
   ```
   npm install -g wrangler
   wrangler login   # one-time OAuth to your Cloudflare account
   ```

2. Create a fine-grained GitHub PAT:
   - Go to https://github.com/settings/personal-access-tokens/new
   - Resource owner: `FalconPulsar`
   - Repository access: only `falconpulsar-installer`
   - Repository permissions: **Contents → Read-only** (no other scopes)
   - Generate and copy the `github_pat_...` string

3. Push the token as a Worker secret:
   ```
   cd infra/cloudflare
   wrangler secret put GITHUB_TOKEN
   # paste the PAT when prompted
   ```

4. Deploy:
   ```
   wrangler deploy
   ```

5. Verify:
   ```
   curl -fsSL https://get.falconpulsar.com/version
   curl -fsSLI https://get.falconpulsar.com/linux      # expect 200, not 302
   curl -fsSL  https://get.falconpulsar.com/linux -o /tmp/linux.sh
   head -5 /tmp/linux.sh                               # expect the bootstrap
   ```

## Subsequent deploys

```
cd infra/cloudflare
wrangler deploy
```

Source changes to `worker.js` need a redeploy; changes to the release
assets themselves don't — the worker always queries GitHub for the
latest release on each request (with a 60-second edge cache for the
release metadata).

## Rotating the PAT

```
cd infra/cloudflare
wrangler secret put GITHUB_TOKEN   # overwrites the existing secret
```

No redeploy needed — the worker reads `env.GITHUB_TOKEN` on each
request.

## Troubleshooting

| Symptom | Check |
|---|---|
| `curl ... | bash` fails with `404 Not Found` | Release tag doesn't exist yet (`git tag` + push), or the asset name in `ROUTES` doesn't match what `release.yml` actually uploaded. Visit `https://get.falconpulsar.com/linux` in a browser — the worker prints the available asset names on 404. |
| `GitHub API 401` | PAT expired or rotated and not pushed. Re-run `wrangler secret put GITHUB_TOKEN`. |
| `GitHub API 403` | PAT doesn't have `Contents: Read` permission for the repo. |
| `Worker is misconfigured: GITHUB_TOKEN secret is not set.` | Run `wrangler secret put GITHUB_TOKEN` for this worker. |

## Rollback to the old 302

If you need to point `get.falconpulsar.com/linux` back at the old
plain-redirect behavior (e.g. the worker is erroring), delete the
route binding in the Cloudflare dashboard (Workers & Pages → this
worker → Settings → Triggers → Routes → remove `get.falconpulsar.com/*`)
and re-enable whatever Page Rule / Transform Rule previously handled
that hostname.
