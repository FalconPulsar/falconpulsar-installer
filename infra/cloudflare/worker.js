/*
 * get.falconpulsar.com — Cloudflare Worker
 *
 * Maps request paths to release-asset filenames, then downloads the asset
 * from the GitHub Releases API using a stored GITHUB_TOKEN (repo :: contents
 * read is enough) and streams the bytes back to the caller.
 *
 * This replaces the previous plain 302 redirect to github.com/.../releases.
 * Because the repo is private, an anonymous curl to the raw GitHub URL
 * returns 404 even after a tag exists. With this worker in front, users
 * still do `curl -fsSL https://get.falconpulsar.com/<path> | sudo bash`
 * and the worker carries the auth on their behalf.
 *
 * Routes handled:
 *   /linux                 -> linux.sh              (bootstrap: install or uninstall)
 *   /linux/install         -> install-linux.sh      (direct install bundle)
 *   /linux/uninstall       -> uninstall-linux.sh    (direct uninstall bundle)
 *   /macos                 -> install-macos.sh
 *   /macos/install         -> install-macos.sh
 *   /macos/uninstall       -> uninstall-macos.sh    (if published)
 *   /windows               -> FalconPulsar-Setup.exe
 *   /version               -> plain-text: release tag name
 *   /                      -> 200 OK plain-text usage hint
 *
 * Secrets (set with `wrangler secret put <NAME>`):
 *   GITHUB_TOKEN   Fine-grained PAT or classic token with "Contents: Read"
 *                  for FalconPulsar/falconpulsar-installer
 *
 * Variables (in wrangler.toml [vars]):
 *   REPO_OWNER     default: FalconPulsar
 *   REPO_NAME      default: falconpulsar-installer
 *   RELEASE_TAG    (optional) pin a specific tag; omit for "latest"
 */

const DEFAULT_OWNER = "FalconPulsar";
const DEFAULT_REPO = "falconpulsar-installer";

// Route table. Keys are normalised lowercase paths without the leading `/`.
const ROUTES = {
  "": "help",
  "linux": "linux.sh",
  "linux/install": "install-linux.sh",
  "linux/uninstall": "uninstall-linux.sh",
  "macos": "install-macos.sh",
  "macos/install": "install-macos.sh",
  "macos/uninstall": "uninstall-macos.sh",
  "windows": "FalconPulsar-Setup.exe",
};

// Content-Type hints so curl-piping + browser downloads both behave.
const CONTENT_TYPES = {
  ".sh":  "text/x-shellscript; charset=utf-8",
  ".exe": "application/vnd.microsoft.portable-executable",
  ".dmg": "application/x-apple-diskimage",
};

function contentTypeFor(name) {
  const m = /\.[^.]+$/.exec(name);
  return (m && CONTENT_TYPES[m[0]]) || "application/octet-stream";
}

function usageText() {
  return [
    "FalconPulsar installer redirector",
    "",
    "Linux:",
    "  curl -fsSL https://get.falconpulsar.com/linux | sudo bash",
    "  curl -fsSL https://get.falconpulsar.com/linux | sudo bash -s -- uninstall",
    "",
    "macOS:",
    "  curl -fsSL https://get.falconpulsar.com/macos | bash",
    "",
    "Windows:",
    "  Download https://get.falconpulsar.com/windows and double-click",
    "",
    "Debug: https://get.falconpulsar.com/version",
    "",
  ].join("\n");
}

async function fetchRelease(env) {
  const owner = env.REPO_OWNER || DEFAULT_OWNER;
  const repo = env.REPO_NAME || DEFAULT_REPO;
  const tagPath = env.RELEASE_TAG ? `tags/${env.RELEASE_TAG}` : "latest";
  const url = `https://api.github.com/repos/${owner}/${repo}/releases/${tagPath}`;
  const res = await fetch(url, {
    headers: {
      "Authorization": `Bearer ${env.GITHUB_TOKEN}`,
      "Accept": "application/vnd.github+json",
      "User-Agent": "falconpulsar-redirector/1.0",
    },
    cf: { cacheTtl: 60, cacheEverything: true }, // cache release metadata ~60s
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`GitHub API ${res.status}: ${body.slice(0, 200)}`);
  }
  return res.json();
}

async function streamAsset(env, asset, filename) {
  // Accept: application/octet-stream tells GitHub to return the binary
  // payload directly (follows redirect to the signed S3 URL for us).
  const res = await fetch(asset.url, {
    headers: {
      "Authorization": `Bearer ${env.GITHUB_TOKEN}`,
      "Accept": "application/octet-stream",
      "User-Agent": "falconpulsar-redirector/1.0",
    },
    redirect: "follow",
  });
  if (!res.ok) {
    const body = await res.text();
    return new Response(`asset fetch ${res.status}: ${body.slice(0, 200)}`, {
      status: 502,
      headers: { "Content-Type": "text/plain" },
    });
  }
  const headers = new Headers();
  headers.set("Content-Type", contentTypeFor(filename));
  headers.set("Content-Disposition", `attachment; filename="${filename}"`);
  headers.set("Cache-Control", "public, max-age=60");
  const cl = res.headers.get("content-length");
  if (cl) headers.set("Content-Length", cl);
  return new Response(res.body, { status: 200, headers });
}

export default {
  async fetch(request, env, _ctx) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/^\/+/, "").replace(/\/+$/, "").toLowerCase();

    if (path === "version") {
      try {
        const rel = await fetchRelease(env);
        return new Response(`${rel.tag_name}\n`, {
          headers: { "Content-Type": "text/plain; charset=utf-8" },
        });
      } catch (e) {
        return new Response(`error: ${e.message}\n`, { status: 502 });
      }
    }

    if (!(path in ROUTES)) {
      return new Response("Not Found\n\n" + usageText(), {
        status: 404,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
    }

    if (ROUTES[path] === "help") {
      return new Response(usageText(), {
        status: 200,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
    }

    if (!env.GITHUB_TOKEN) {
      return new Response(
        "Worker is misconfigured: GITHUB_TOKEN secret is not set.\n" +
          "Run: wrangler secret put GITHUB_TOKEN\n",
        { status: 500, headers: { "Content-Type": "text/plain; charset=utf-8" } }
      );
    }

    const filename = ROUTES[path];
    try {
      const rel = await fetchRelease(env);
      const asset = (rel.assets || []).find((a) => a.name === filename);
      if (!asset) {
        return new Response(
          `Asset not found in release ${rel.tag_name}: ${filename}\n` +
            `Available: ${(rel.assets || []).map((a) => a.name).join(", ")}\n`,
          { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8" } }
        );
      }
      return await streamAsset(env, asset, filename);
    } catch (e) {
      return new Response(`Release lookup failed: ${e.message}\n`, {
        status: 502,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
    }
  },
};
