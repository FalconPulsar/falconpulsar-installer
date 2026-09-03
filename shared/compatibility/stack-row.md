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

## Current row (useful-loops)

| FP_VERSION | core | ui | gateway | engine | installer |
|------------|------|----|---------|--------|-----------|
| useful-loops | latest | useful-loops (unreleased) | useful-loops | useful-loops | useful-loops |

- **core** stays on `main` / the published `latest` image. Contracts
  (BrowseNext, permission bits, …) are written in falconpulsar-doc, not
  implemented on this stack.
- **ui** is the useful-loops branch, not a registry tag yet.
- **gateway**, **engine**, **installer** are the useful-loops branches.

The docs copy of this row: getting-started/compatibility.
