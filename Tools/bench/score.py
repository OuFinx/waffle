import json, re, sys, collections
def match(m, labels, spks):
    """Best one-to-one sum of m[(label, speaker)] (Hungarian method; a label or speaker may stay unmatched)."""
    n = max(len(labels), len(spks)); INF = float("inf")
    c = [[-(m[(labels[i], spks[j])] if i < len(labels) and j < len(spks) and labels[i] else 0) for j in range(n)] for i in range(n)]
    u, v, p, way = [0] * (n + 1), [0] * (n + 1), [0] * (n + 1), [0] * (n + 1)
    for i in range(1, n + 1):
        p[0], j0 = i, 0; minv, used = [INF] * (n + 1), [False] * (n + 1)
        while p[j0]:
            used[j0] = True; i0, d, j1 = p[j0], INF, 0
            for j in range(1, n + 1):
                if not used[j]:
                    cur = c[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j]: minv[j], way[j] = cur, j0
                    if minv[j] < d: d, j1 = minv[j], j
            for j in range(n + 1):
                if used[j]: u[p[j]] += d; v[j] -= d
                else: minv[j] -= d
            j0 = j1
        while j0: j1 = way[j0]; p[j0] = p[j1]; j0 = j1
    return -sum(c[p[j] - 1][j - 1] for j in range(1, n + 1) if p[j])
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
# word-level: each reference word goes to the line whose recognized words (token times) hold its middle, a fairer truth than [t, next t)
words = []
if "windows" in out:
    toks = {round(x["w"], 3): [x["w"] + a for a, b, _ in x["tokens"]] for x in out["windows"]}
    ends = {round(x["w"], 3): [x["w"] + b for a, b, _ in x["tokens"]] for x in out["windows"]}
    span = []
    for k, l in enumerate(L):
        w = round(l["w"], 3); nxt = min([m["t"] for m in L if round(m["w"], 3) == w and m["t"] > l["t"]], default=1e9)
        e = max([b for a, b in zip(toks.get(w, []), ends.get(w, [])) if l["t"] - 0.02 <= a < nxt - 0.02], default=l["t"] + 0.5)
        span.append((l["t"] - 0.15, e + 0.15))
    for a, b, spk, _ in ref:
        mid = (a + b) / 2
        c = [k for k, (s, e) in enumerate(span) if s <= mid <= e]
        if c: words.append((min(c, key=lambda k: abs(sum(span[k]) / 2 - mid)), spk))
for key in ("live", "polish"):
    if words:
        m = collections.Counter((L[k][key], spk) for k, spk in words); labels = sorted({L[k][key] for k, _ in words})
        best = match(m, labels, spks)
        print(f"[{key}] words with the right voice {best / len(words) * 100:.1f}% of {len(words)} reference words in lines")
for key in ("live", "polish"):
    pairs = [(l[key], t) for l, t in zip(L, truth) if t]
    labels = sorted({p[0] for p in pairs})
    m = collections.Counter(pairs)
    purity = sum(max(m[(lab, s)] for s in spks) for lab in labels) / len(pairs)
    best = match(m, labels, spks)
    print(f"\n[{key}] labels {len(labels)}; purity {purity * 100:.0f}%, one-to-one {best / len(pairs) * 100:.0f}% of lines")
    print("        " + " ".join(f"{s:>5}" for s in spks))
    for lab in labels: print(f"  {lab or '-':>5} " + " ".join(f"{m[(lab, s)]:>5}" for s in spks))
