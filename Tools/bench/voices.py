# voices.py <data> <out dir> <ICSI annotations dir> <meetings...>: how well a voice named in one meeting is told in later ones (run.sh voices).
# Each voice found after the call is the person who speaks most of its time (ICSI's speaker ids, the same person across meetings). The user
# names the voices that speak long enough (enrolled), then every voice of the later meetings is matched as knownVoices in Logic.swift does
# (keep the two the same): named right, named wrong (the costly error), or left unnamed (when its person was enrolled, or not).
import json, math, re, os, sys, collections
data, out, icsi, ms = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
ENROLL = 20  # seconds of a voice before the user's name for it makes or updates a profile (Logic.swift voiceLeast)

def unit(v):
    n = math.sqrt(sum(x * x for x in v)) or 1
    return [x / n for x in v]

def voices(m, v):
    off = float(open(f"{data}/{m}.off").read().split()[0])
    who = {}
    for f in os.listdir(f"{icsi}/Segments"):
        if f.startswith(m + "."):
            p = re.findall(r'participant="([^"]*)"', open(f"{icsi}/Segments/{f}").read())
            if p: who[f.split(".")[1]] = p[0]
    ref = [(s - off, e - off, who.get(l, l)) for s, e, l, _ in json.load(open(f"{data}/{m}.ref.json"))]
    r = json.load(open(f"{out}/{m}{v}.json"))
    talk, secs = collections.defaultdict(collections.Counter), collections.Counter()
    for s, e, spk in r["turns"]:
        secs[spk] += e - s
        for a, b, p in ref:
            x = min(b, e) - max(a, s)
            if x > 0: talk[spk][p] += x
    return {spk: (talk[spk].most_common(1)[0][0] if talk[spk] else None, secs[spk], unit(r["prints"][spk])) for spk in r["prints"]}

def match(prints, known, least, margin):  # Logic.swift knownVoices
    cos = lambda a, b: sum(x * y for x, y in zip(a, b))
    best = {}
    for v, e in prints.items():
        s = sorted(((cos(e, k), n) for n, k in known.items()), reverse=True)
        if s and s[0][0] >= least and (len(s) == 1 or s[0][0] - s[1][0] >= margin): best[v] = (s[0][1], s[0][0])
    return {v: n for v, (n, sc) in best.items() if all(sc > o[1] or (sc == o[1] and v < w) for w, o in best.items() if w != v and o[0] == n)}

def enroll(known, counts, vs):  # the user names voices by who they are; Logic.swift addPrint
    for p, sec, e in vs.values():
        if p and sec >= ENROLL:
            c = counts[p]; old = known.get(p, [0] * len(e))
            known[p] = unit([(o * c + x) / (c + 1) for o, x in zip(old, e)]); counts[p] = c + 1

def score(rows, vs, known, least, margin):
    got = match({k: x[2] for k, x in vs.items()}, known, least, margin)
    for k, (p, sec, _) in vs.items():
        n = got.get(k)
        rows["right" if n == p else "WRONG" if n else "missed" if p in known else "unknown"] += 1

TH = [0.6, 0.65, 0.7, 0.75, 0.8, 0.85]
for v in ["", "-opus"]:
    V = {m: voices(m, v) for m in ms}
    print(f"\n{v or 'plain'}: {sum(len(x) for x in V.values())} voices in {len(ms)} meetings")
    for margin in [0.1, 0.2]:
        print(f"  margin {margin}   one meeting enrolled, every other matched     |  meetings in order, each one named after it is matched")
        for least in TH:
            a, b = collections.Counter(), collections.Counter()
            for e in ms:
                known, counts = {}, collections.Counter()
                enroll(known, counts, V[e])
                for x in ms:
                    if x != e: score(a, V[x], known, least, margin)
            known, counts = {}, collections.Counter()
            for x in ms:
                score(b, V[x], known, least, margin); enroll(known, counts, V[x])
            f = lambda r: f"right {r['right']:4} wrong {r['WRONG']:3} ({r['WRONG'] / max(1, r['right'] + r['WRONG']) * 100:4.1f}% of named) missed {r['missed']:4} unknown {r['unknown']:4}"
            print(f"  >= {least:.2f}  {f(a)}  |  {f(b)}")
