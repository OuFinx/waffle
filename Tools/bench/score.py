import json, re, sys, itertools, collections
ref = json.load(open(sys.argv[1])); out = json.load(open(sys.argv[2])); off = float(sys.argv[3])
FILL = {"uh", "um", "mm", "hmm", "mmm", "huh", "uh-huh", "mm-hmm", "ah", "oh", "eh", "hm"}
def norm(ws):
    r = []
    for w in ws:
        w = w.lower().replace("-", " ")
        for x in re.findall(r"[a-z0-9']+", w):
            x = x.strip("'")
            if x and x not in FILL: r.append(x)
    return r
def wer(r, h):
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        p, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            c = d[j]; d[j] = min(d[j] + 1, d[j - 1] + 1, p + (r[i - 1] != h[j - 1])); p = c
    return d[len(h)] / len(r)
ref = [(s - off, e - off, spk, w) for s, e, spk, w in ref]
R = norm(w for *_, w in ref); L = out["lines"]; H = norm(l["text"] for l in L)
print(f"audio {out['audio']:.0f} s, processed in {out['liveTime']:.0f} s (asr {out['asrTime']:.0f}, vad {out['vadTime']:.0f}, live diar {out['diarTime']:.0f}), {out['passes']} passes, thin retries {out['thinRetries']}, tape {out['tape']:.0f} s")
print(f"words: ref {len(R)}, hyp {len(H)}, WER {wer(R, H) * 100:.1f}%  (recall by multiset {sum((collections.Counter(R) & collections.Counter(H)).values()) / len(R) * 100:.1f}%)")
print(f"lines {len(L)}, live voices {out['liveVoices']}, after-call voices {out['offVoices']}, after-call used: {out['polishUsed']}")
# true speaker of each line: most reference word time in [t, next t)
truth = []
for k, l in enumerate(L):
    s = l["t"]; e = min(L[k + 1]["t"], s + 10) if k + 1 < len(L) else s + 4
    o = collections.Counter()
    for a, b, spk, _ in ref:
        x = min(b, e) - max(a, s)
        if x > 0: o[spk] += x
    truth.append(o.most_common(1)[0][0] if o else None)
spks = sorted({r[2] for r in ref})
print("true lines per speaker:", dict(collections.Counter(t for t in truth if t)))
for key in ("live", "polish"):
    pairs = [(l[key], t) for l, t in zip(L, truth) if t]
    labels = sorted({p[0] for p in pairs})
    m = collections.Counter(pairs)
    purity = sum(max(m[(lab, s)] for s in spks) for lab in labels) / len(pairs)
    best = 0
    for perm in itertools.permutations(labels + [None] * max(0, len(spks) - len(labels)), len(spks)):
        best = max(best, sum(m[(lab, s)] for lab, s in zip(perm, spks) if lab))
    print(f"\n[{key}] labels {len(labels)}; purity {purity * 100:.0f}%, one-to-one {best / len(pairs) * 100:.0f}% of lines")
    print("        " + " ".join(f"{s:>5}" for s in spks))
    for lab in labels: print(f"  {lab or '-':>5} " + " ".join(f"{m[(lab, s)]:>5}" for s in spks))
