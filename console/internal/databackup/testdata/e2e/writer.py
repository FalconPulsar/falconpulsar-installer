#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors
"""Load writer for the fp backup e2e (testdata only).

Points: K series p<i>@bk/pts, point j of series i at ts = BASE + j*STEP, value j.
Catalog: series c<n>@bk/cat/g<n//GROUP> created one by one (one catalog commit each).
Every acknowledged request is logged with the wall clock AFTER the 2xx arrived:
  acks/pts-<t>.log : "<ns> <series> <last_j>"
  acks/cat.log     : "<ns> <n>"
Stops when <dir>/stop exists.
"""
import http.client, json, os, sys, threading, time, argparse

BASE = 1700000000000000000
STEP = 1048576  # 2^20 ns: a multiple of 256, so JSON doubles keep it exact

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=7433)
ap.add_argument("--dir", required=True)
ap.add_argument("--series", type=int, default=40)
ap.add_argument("--batch", type=int, default=250)
ap.add_argument("--pts-threads", type=int, default=4)
ap.add_argument("--cat-threads", type=int, default=1)
ap.add_argument("--cat-start", type=int, default=0)
ap.add_argument("--group", type=int, default=500)
ap.add_argument("--setup-only", action="store_true")
ap.add_argument("--rate", type=float, default=0, help="total points/s cap (0 = unlimited)")
ap.add_argument("--cat-rate", type=float, default=0, help="catalog creates/s cap per thread")
ap.add_argument("--bulk-cat", type=int, default=0, help="pre-create this many catalog series via /series/bulk")
ap.add_argument("--str-series", type=int, default=0)
ap.add_argument("--str-batch", type=int, default=20)
ap.add_argument("--str-rate", type=float, default=50, help="string requests/s")
a = ap.parse_args()
os.makedirs(a.dir + "/acks", exist_ok=True)
PASS = os.environ.get("E2E_PASS", "Adm1n-pass-e2e-test")


class Client:
    def __init__(self):
        self.c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=60)
        self.login()

    def login(self):
        for _ in range(60):
            try:
                st, body = self.raw("POST", "/api/v1/auth/login", {"username": "admin", "password": PASS}, auth=False)
                if st == 200:
                    self.tok = json.loads(body)["token"]
                    return
            except Exception:
                self.c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=60)
            time.sleep(1)
        raise SystemExit("login failed")

    def raw(self, m, path, body=None, auth=True):
        h = {"Content-Type": "application/json"}
        if auth:
            h["Authorization"] = "Bearer " + self.tok
        self.c.request(m, path, body=json.dumps(body) if body is not None else None, headers=h)
        r = self.c.getresponse()
        return r.status, r.read()

    def req(self, m, path, body=None):
        try:
            st, b = self.raw(m, path, body)
        except Exception:
            self.c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=60)
            return 0, b""
        if st == 401:
            self.login()
            st, b = self.raw(m, path, body)
        return st, b


def stopped():
    return os.path.exists(a.dir + "/stop")


def setup():
    c = Client()
    c.req("POST", "/api/v1/assets", {"path": "bk/pts"})
    for i in range(a.series):
        c.req("POST", "/api/v1/series", {"asset": "bk/pts", "name": "p%d" % i, "data_type": "float64"})
    if a.str_series:
        c.req("POST", "/api/v1/assets", {"path": "bk/str"})
        for i in range(a.str_series):
            st, b = c.req("POST", "/api/v1/series", {"asset": "bk/str", "name": "s%d" % i, "data_type": "string"})
            if st not in (200, 201, 409):
                print("str create", i, st, b[:200], file=sys.stderr)
    if a.bulk_cat:
        made = 0
        for g0 in range(0, a.bulk_cat, a.group):
            g = g0 // a.group
            c.req("POST", "/api/v1/assets", {"path": "bk/cat/g%d" % g})
            ser = [{"asset": "bk/cat/g%d" % g, "name": "c%d" % n, "data_type": "float64"}
                   for n in range(g0, min(g0 + a.group, a.bulk_cat))]
            st, b = c.req("POST", "/api/v1/series/bulk", {"series": ser})
            if st != 200:
                print("bulk", st, b[:200], file=sys.stderr)
            made += len(ser)
        # bulk-made series are acknowledged long before any copy: log them at ns 1
        with open(a.dir + "/acks/cat-bulk.log", "w") as f:
            for n in range(a.bulk_cat):
                f.write("1 %d\n" % n)
        print("bulk catalog series", made, file=sys.stderr)


def pts_worker(t):
    c = Client()
    mine = [i for i in range(a.series) if i % a.pts_threads == t]
    nxt = {i: 0 for i in mine}
    f = open(a.dir + "/acks/pts-%d.log" % t, "a", buffering=1 << 16)
    last_flush = time.time()
    per = (a.batch / (a.rate / a.pts_threads)) if a.rate else 0
    nexttime = time.time()
    while not stopped():
        for i in mine:
            if per:
                nexttime += per
                d = nexttime - time.time()
                if d > 0:
                    time.sleep(d)
            j0 = nxt[i]
            pts = [{"timestamp": BASE + (j0 + k) * STEP, "value": float(j0 + k)} for k in range(a.batch)]
            st, b = c.req("POST", "/api/v1/series/p%d@bk/pts" % i, {"points": pts})
            if st == 201:
                d = json.loads(b)
                if d.get("inserted") == a.batch:
                    nxt[i] = j0 + a.batch
                    f.write("%d %d %d\n" % (time.time_ns(), i, j0 + a.batch - 1))
                else:
                    print("partial insert", i, d, file=sys.stderr)
                    nxt[i] = j0 + a.batch  # do not reuse timestamps
            elif st:
                print("insert", i, st, b[:200], file=sys.stderr)
                time.sleep(0.2)
        if time.time() - last_flush > 0.5:
            f.flush()
            last_flush = time.time()
    f.close()


def cat_worker(t):
    c = Client()
    f = open(a.dir + "/acks/cat-%d.log" % t, "a", buffering=1 << 12)
    n = a.cat_start + t
    made_groups = set()
    nexttime = time.time()
    while not stopped():
        if a.cat_rate:
            nexttime += 1.0 / a.cat_rate
            d = nexttime - time.time()
            if d > 0:
                time.sleep(d)
        g = n // a.group
        if g not in made_groups:
            c.req("POST", "/api/v1/assets", {"path": "bk/cat/g%d" % g})
            made_groups.add(g)
        st, b = c.req("POST", "/api/v1/series", {"asset": "bk/cat/g%d" % g, "name": "c%d" % n, "data_type": "float64"})
        if st == 201:
            f.write("%d %d\n" % (time.time_ns(), n))
            f.flush()
        elif st:
            print("cat create", n, st, b[:200], file=sys.stderr)
            time.sleep(0.2)
        n += a.cat_threads
    f.close()


def str_worker():
    c = Client()
    nxt = {i: 0 for i in range(a.str_series)}
    f = open(a.dir + "/acks/str.log", "a", buffering=1 << 12)
    nexttime = time.time()
    while not stopped():
        for i in range(a.str_series):
            nexttime += 1.0 / a.str_rate
            d = nexttime - time.time()
            if d > 0:
                time.sleep(d)
            j0 = nxt[i]
            pts = [{"timestamp": BASE + (j0 + k) * STEP, "value": "v%d-%d" % (j0 + k, i)} for k in range(a.str_batch)]
            st, b = c.req("POST", "/api/v1/series/s%d@bk/str" % i, {"points": pts})
            if st == 201:
                nxt[i] = j0 + a.str_batch
                f.write("%d %d %d\n" % (time.time_ns(), i, j0 + a.str_batch - 1))
                f.flush()
            elif st:
                print("str insert", i, st, b[:200], file=sys.stderr)
                time.sleep(0.2)
    f.close()


setup()
if a.setup_only:
    sys.exit(0)
ths = [threading.Thread(target=pts_worker, args=(t,)) for t in range(a.pts_threads)]
ths += [threading.Thread(target=cat_worker, args=(t,)) for t in range(a.cat_threads)]
if a.str_series:
    ths.append(threading.Thread(target=str_worker))
for th in ths:
    th.start()
for th in ths:
    th.join()
