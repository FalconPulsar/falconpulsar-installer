#!/usr/bin/env python3
"""
Fail the build if a real customer's identifiers reach a tracked file.

Why this exists: this repository carried a pilot customer's field-site names, the PLC
model at each and the production MQTT topic root, across fixtures and production source.
It is public now, so this guard keeps them from returning.

It scans tracked files only, so testing against real data locally stays possible — the
guard fires the moment such a file is staged for commit.

WHY THE TOKENS ARE HASHED, NOT ENCODED
--------------------------------------
An earlier version carried the identifiers base64-encoded, so that a history rewrite
(git filter-repo --replace-text rewrites every blob, including this one) could not silently
turn the guard's own patterns into the synthetic replacements. That solved the rewrite
problem and created a worse one: this file became a complete, annotated, trivially
reversible roster of the customer's real names — in a public repo, and for several tokens
the only surviving copy of them anywhere.

Hashing fixes both. A digest cannot be rewritten into a synthetic name by a text filter,
and it cannot be read back into one either. The guard can still ANSWER "is this token one
of the forbidden ones?" without being able to ENUMERATE them.

The cost is that matching is now token-exact rather than substring: text is split into
word tokens and each is hashed. That is why these names are split on underscores too —
"site01_plc1" is checked as the tokens "site01" and "plc1", not as one string.

Nothing in this file or its CI job names a customer or an internal host, in clear text
or encoded: the internal addresses are digests too, and the CI self-test plants synthetic
canaries whose digests it adds for that run only (FP_GUARD_EXTRA_DIGESTS, below).

Run:  python3 tools/check_no_customer_data.py
CI:   see .github/workflows/no-customer-data.yml
"""
import hashlib
import os
import re
import subprocess
import sys

# sha256(token)[:16] for the distinctive identifiers. Not reversible; not enumerable.
_DIGESTS = {
    "6a517b67e8785559", "b00ef262afae566b", "3ed119d79cd3991c", "902eb55bad494a77",
    "013c297d2e5d7abc", "52b4f7b6c5b52d1b", "eb796444f195ab91", "ca5bb09b7589f4a1",
    "bbaa07561f3ff3ad", "43e26a97aa61e86d",
}

# The shortest listed identifier is three characters, and nothing shorter is listed. A
# digest match is exact, so a short token cannot fire on ordinary code; it only fires on
# a listed name. The minimum was 4, which made a listed three-letter code invisible: it
# sat in tests and in a user-facing sentence while this check passed.
_MIN_TOKEN = 3

# These four are ordinary English words as well as site names, so a token match would fire
# on prose and on this project's maritime icon registry. They are only reported in
# series-path shape — followed by _ or @. Left in cleartext deliberately: as English words
# they disclose essentially nothing, and the context requirement cannot survive hashing.
_AMBIGUOUS = ["crane", "independence", "trenton", "reeves"]
_PATH_SHAPED = [
    (re.compile(r"(?<![A-Za-z])" + w + r"(?=[_@])", re.IGNORECASE), "field site (path-shaped)")
    for w in _AMBIGUOUS
]

# Specific internal hosts, as sha256(address)[:16]. Deliberately NOT all of RFC1918 —
# flagging 192.168.1.100 in an ordinary datasource example is noise, and noisy guards get
# switched off. Hashed like the names, so that a copy of this guard in a public repo does
# not publish the addresses it guards.
_ADDRESS_DIGESTS = {
    "0546412d61ba57f1", "a9df51678f7ba701", "fe84b09a859af879",
}
_ADDRESS_RE = re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])")

# Digests added for one run, comma-separated, for the CI self-test's synthetic canaries.
# They count as names and as addresses alike.
_EXTRA = {x.strip() for x in os.environ.get("FP_GUARD_EXTRA_DIGESTS", "").split(",") if x.strip()}
_DIGESTS |= _EXTRA
_ADDRESS_DIGESTS |= _EXTRA

# Vendor and product names that are NOT customer data and must never be scrubbed:
# ab-rockwel / ab-ethernetip are Allen-Bradley Rockwell driver names. A previous scrub
# rewrote ab-rockwel to beta-rockwel believing 'ab' was a tenant code, and updated a token
# assertion to expect the corrupted spelling — so it passed while being wrong.
ALLOWED_SUBSTRINGS = ("ab-rockwel", "ab-ethernetip", "anthropic-beta")

_TOKEN_RE = re.compile(r"[A-Za-z0-9]+")


def tracked_files():
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout
    return [f for f in out.splitlines() if f]


def scan(text):
    """Yield (kind, matched_text, line_offset) for anything forbidden."""
    for m in _TOKEN_RE.finditer(text):
        tok = m.group(0)
        if len(tok) < _MIN_TOKEN:
            continue
        if hashlib.sha256(tok.lower().encode()).hexdigest()[:16] in _DIGESTS:
            yield "customer identifier", tok, m.start()
    for pat, what in _PATH_SHAPED:
        for m in pat.finditer(text):
            yield what, m.group(0), m.start()
    for m in _ADDRESS_RE.finditer(text):
        if hashlib.sha256(m.group(0).encode()).hexdigest()[:16] in _ADDRESS_DIGESTS:
            yield "internal address (known)", m.group(0), m.start()


def main():
    violations = []
    for path in tracked_files():
        # Both files must reference the machinery to do their job.
        if path in ("tools/check_no_customer_data.py",
                    ".github/workflows/no-customer-data.yml"):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except (OSError, IsADirectoryError):
            continue
        if "\0" in text[:8000]:
            continue
        lines = text.splitlines()
        for what, tok, off in scan(text):
            line_no = text.count("\n", 0, off) + 1
            line = lines[line_no - 1] if line_no <= len(lines) else ""
            if any(a in line for a in ALLOWED_SUBSTRINGS):
                continue
            violations.append((path, line_no, what, tok))

    if violations:
        print("Customer identifiers found in tracked files:\n", file=sys.stderr)
        for path, line_no, what, tok in violations[:50]:
            print(f"  {path}:{line_no}  {tok!r}  ({what})", file=sys.stderr)
        if len(violations) > 50:
            print(f"  ... and {len(violations) - 50} more", file=sys.stderr)
        print(
            "\nThese repositories are, or will be, published. Replace these with synthetic\n"
            "values before committing.\n"
            "Use the synthetic vocabulary: site01/site02, plc, @plant1, @line1, /plant/.",
            file=sys.stderr,
        )
        return 1

    print(f"OK — no customer identifiers in {len(tracked_files())} tracked files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
