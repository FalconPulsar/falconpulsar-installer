#!/usr/bin/env python3
"""Syntax-check the bash scripts EMBEDDED in the Windows PowerShell helpers.

The Windows installer runs bash inside WSL by generating scripts as PowerShell
here-strings (@'...'@ / @"..."@) and handing them to `Invoke-WslBash` / `wsl.exe
-- bash`. shellcheck on standalone *.sh files never sees these, so a quoting or
CRLF bug in an embedded script only blew up when a user ran the installer on a
real machine (e.g. the `set: +` and `sed '...'"$U"/'` bugs). This runs `bash -n`
on every embedded here-string so those are caught in CI instead.

Exit non-zero if any embedded script fails to parse.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPERS = sorted(
    glob.glob(os.path.join(HERE, "..", "helpers", "*.ps1"))
    + glob.glob(os.path.join(HERE, "..", "*.ps1"))
)

# @'...'@  = literal (verbatim bash);  @"..."@ = interpolated by PowerShell.
BLOCK = re.compile(r"@(['\"])\r?\n(.*?)\r?\n\1@", re.S)
PSVAR = re.compile(r"(?<!\\)\$(\w+|\{\w+\})")

# Only check blocks that are actually bash. Heuristic: they contain a bash-ism.
BASHY = re.compile(r"(^|\n)\s*(set -e|if \[|for \b|while \b|useradd|getent|"
                   r"docker |sed -i|grep -q|printf |echo |cat >|mkdir |rm -rf|\. \")")


def to_bash(kind: str, body: str) -> str:
    """Reproduce what bash actually receives."""
    if kind == '"':  # interpolated: `$ -> $ (real bash var); $PsVar was substituted
        body = (body.replace("`$", "$").replace('`"', '"')
                    .replace("`'", "'").replace("``", "`"))
        body = PSVAR.sub("X", body)  # value-agnostic: any remaining $Word -> X
    return body


def main() -> int:
    failures = 0
    checked = 0
    for ps in HELPERS:
        src = open(ps, encoding="utf-8").read()
        for m in BLOCK.finditer(src):
            kind, raw = m.group(1), m.group(2)
            if not BASHY.search(raw):
                continue  # not a bash here-string (e.g. a plist / JSON blob)
            line = src[:m.start()].count("\n") + 1
            script = to_bash(kind, raw)
            with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
                f.write(script)
                tmp = f.name
            r = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
            os.unlink(tmp)
            checked += 1
            tag = f"{os.path.basename(ps)}:~{line}"
            if r.returncode != 0:
                failures += 1
                print(f"FAIL {tag}\n{r.stderr.strip()}", file=sys.stderr)
            else:
                print(f"ok   {tag}")
    print(f"\nchecked {checked} embedded bash script(s), {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
