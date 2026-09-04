# Stack row — five components

One row names the images that belong together. Columns are fixed: **core**,
**ui**, **gateway** (ai-gateway), **engine** (ai-engine), **installer**.
The first four cells are Docker Hub tags; the installer cell is a GitHub
release (the DMG / EXE / install.sh package and the `fp` CLI are host
components, not an image). Do not add a sixth component (Command Center is
an optional compose profile on the installer, not a column).

`FP_VERSION` in `.env` is the tag every image is supposed to share. When a
branch is mid-flight the five cells may differ; write the mixed row instead
of pretending they match.

Template:

```
| FP_VERSION | core | ui | gateway | engine | installer |
|------------|------|----|---------|--------|-----------|
| <stack>    |      |    |         |        |           |
```

## Current row

| FP_VERSION | core | ui | gateway | engine | installer |
|------------|------|----|---------|--------|-----------|
| latest | latest | latest | latest | latest | current GitHub release |

Official installs set `FP_VERSION=latest` and pull every image from the
registry. Git branch names are not Hub tags.

- **core** stays on `main` / the published `latest` image. Contracts
  (BrowseNext, permission bits, …) are written in falconpulsar-doc, not
  implemented in that image.
- **ui**, **gateway**, **engine** share the same `latest` tag; each repo
  releases on its own alpha number, so a pinned `FP_VERSION` must exist for
  all four images. Copilot is an optional profile (`FP_COPILOT_IMAGE_TAG`,
  defaulting to `FP_VERSION`). The **installer** cell is the GitHub release
  the host was installed from.

The docs copy of this row: getting-started/compatibility.
