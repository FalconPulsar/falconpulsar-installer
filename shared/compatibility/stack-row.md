# Stack row — five components

One row names the images that belong together. Columns are fixed: **core**,
**ui**, **gateway** (ai-gateway), **engine** (ai-engine), **installer**.
Do not add a sixth component (Command Center is an optional compose profile
on the installer, not a column).

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
| latest | latest | latest | latest | latest | latest |

Official installs set `FP_VERSION=latest` and pull every image from the
registry. Git branch names are not Hub tags.

- **core** stays on `main` / the published `latest` image. Contracts
  (BrowseNext, permission bits, …) are written in falconpulsar-doc, not
  implemented in that image.
- **ui**, **gateway**, **engine**, **installer** share the same `latest`
  tag. Copilot is an optional profile and also pulls `latest`.

The docs copy of this row: getting-started/compatibility.
