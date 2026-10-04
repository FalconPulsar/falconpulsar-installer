#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors
"""Open a restored Core data directory with a second Core and check it against
every acknowledgement logged before t0: each point once, with its value; each
string once, with its text; each catalog series present. Testdata for the fp backup e2e."""
import argparse, glob, http.client, json, os, re, signal, subprocess, time

BASE = 1700000000000000000
STEP = 1048576
ap = argparse.ArgumentParser()
ap.add_argument("--data", required=True)
ap.add_argument("--acks", required=True)
ap.add_argument("--t0", type=int, required=True)
ap.add_argument("--port", type=int, default=7733)
ap.add_argument("--group", type=int, default=500)
ap.add_argument("--label", default="")
ap.add_argument("--live", action="store_true", help="check the Core already listening on --port; start none")
a = ap.parse_args()
PASS = os.environ.get("E2E_PASS", "Adm1n-pass-e2e-test")
out = {"label": a.label, "data": a.data}
log = a.data.rstrip("/") + ".server.log"
cfg = os.path.join(a.data, "falconpulsar.toml")
cmd = ["/build/falconpulsar-server", "-V", "-d", a.data, "--bind", "127.0.0.1", "-p", str(a.port),
       "--ws-port", str(a.port + 1), "--metrics-port", str(a.port + 2), "--log-level", "info"]
if os.path.exists(cfg):
    cmd[2:2] = ["-c", cfg]
proc = None if a.live else subprocess.Popen(cmd, stdout=open(log, "w"), stderr=subprocess.STDOUT)
tok = None


def req(m, path, body=None):
    for attempt in range(60):
        c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=120)
        h = {"Content-Type": "application/json"}
        if tok:
            h["Authorization"] = "Bearer " + tok
        c.request(m, path, body=json.dumps(body) if body is not None else None, headers=h)
        r = c.getresponse()
        data = r.read()
        if r.status != 429:   # Core's rate limiter: wait and ask again
            return r.status, data
        time.sleep(0.5)
    return r.status, data


t_start = time.time()
ready = False
while time.time() - t_start < 300:
    if proc is not None and proc.poll() is not None:
        break
    try:
        st, _ = req("POST", "/api/v1/auth/login", {"username": "admin", "password": PASS})
        if st in (200, 401, 403):
            ready = True
            break
    except Exception:
        pass
    time.sleep(0.5)
out["open_seconds"] = round(time.time() - t_start, 1)
out["opened"] = ready


def history(path, last):
    """Every point of path from index 0 to last: {index: [values...]}."""
    got = {}
    start, end = BASE, BASE + last * STEP
    errors = 0
    while start <= end:
        st, b = req("GET", "/api/v1/series/%s/history?start=%d&end=%d&limit=10000" % (path, start, end))
        if st != 200:
            errors += 1
            break
        d = json.loads(b)
        pts = d.get("points", [])
        for p in pts:
            ts = int(p["timestamp"])
            got.setdefault((ts - BASE) // STEP, []).append(p.get("value"))
        if not pts or not d.get("has_more"):
            break
        start = int(pts[-1]["timestamp"]) + 1
    return got, errors


def check(prefix, logs, expect):
    last = {}
    for fn in glob.glob(os.path.join(a.acks, logs)):
        for line in open(fn):
            p = line.split()
            if len(p) == 3 and int(p[0]) < a.t0:
                s, j = int(p[1]), int(p[2])
                last[s] = max(last.get(s, -1), j)
    res = {"series": len(last), "acked_before_t0": 0, "missing": 0, "duplicates": 0, "wrong_values": 0,
           "errors": 0, "samples": []}
    for s, j in sorted(last.items()):
        got, errors = history(prefix % s, j)
        res["errors"] += errors
        res["acked_before_t0"] += j + 1
        for k in range(j + 1):
            vals = got.get(k)
            if not vals:
                res["missing"] += 1
                if len(res["samples"]) < 5:
                    res["samples"].append(["missing", prefix % s, k])
                continue
            if len(vals) > 1:
                res["duplicates"] += len(vals) - 1
                if len(res["samples"]) < 5:
                    res["samples"].append(["dup", prefix % s, k, len(vals)])
            if vals[0] != expect(s, k):
                res["wrong_values"] += 1
                if len(res["samples"]) < 5:
                    res["samples"].append(["value", prefix % s, k, vals[0]])
    return res


if ready:
    st, b = req("POST", "/api/v1/auth/login", {"username": "admin", "password": PASS})
    out["login"] = st
    if st == 200:
        tok = json.loads(b)["token"]
        st, b = req("GET", "/api/v1/_system/catalog")
        try:
            cat = json.loads(b)["catalog"]
            out["catalog"] = {"write_state": cat.get("write_state"),
                              "open": {k: cat["open"].get(k) for k in ("damaged", "journal_replayed", "journal_ignored", "journal_note")},
                              "wal_held": {k: cat["wal_held"].get(k) for k in ("series", "points")}}
        except Exception:
            out["catalog"] = {"status": st, "raw": b[:300].decode(errors="replace")}
        exp = set()
        for fn in glob.glob(a.acks + "/cat*.log"):
            for line in open(fn):
                p = line.split()
                if len(p) == 2 and int(p[0]) < a.t0:
                    exp.add(int(p[1]))
        missing = []
        for n in sorted(exp):
            st, _ = req("GET", "/api/v1/series/c%d@bk/cat/g%d" % (n, n // a.group))
            if st != 200:
                missing.append((n, st))
        out["cat"] = {"acked_before_t0": len(exp), "missing": len(missing), "sample": missing[:5]}
        out["pts"] = check("p%d@bk/pts", "pts-*.log", lambda s, k: float(k))
        out["str"] = check("s%d@bk/str", "str.log", lambda s, k: "v%d-%d" % (k, s))
    if proc is not None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(120)
        except subprocess.TimeoutExpired:
            proc.kill()
            out["kill"] = True
elif proc is not None:
    out["exit_code"] = proc.poll()
pat = re.compile(r"(ERROR|DAMAG|journal|held|quarantin|replayed|corrupt|reconcil)", re.I)
out["log"] = [] if a.live else [re.sub(r"^\S+ \S+ ", "", l.rstrip())[:220] for l in open(log, errors="replace") if pat.search(l)][:20]
ok = (ready and out.get("pts", {}).get("missing") == 0 and out["pts"].get("duplicates") == 0 and out["pts"].get("wrong_values") == 0
      and out.get("str", {}).get("missing") == 0 and out["str"].get("duplicates") == 0 and out["str"].get("wrong_values") == 0
      and out.get("cat", {}).get("missing") == 0 and not out.get("catalog", {}).get("open", {}).get("damaged"))
out["PASS"] = bool(ok)
print(json.dumps(out, indent=1))
