# uk.py <out.json> [<subs.json3> <segment start s>]: Russian-looking vs Ukrainian-looking words, voices, and a rough WER against YouTube auto-captions
import json, re, sys, collections
out = json.load(open(sys.argv[1])); L = out["lines"]
text = " ".join(l["text"] for l in L).lower()
ws = re.findall(r"[a-zа-яіїєґёыэъ']+", text)
ru = [w for w in ws if re.search("[ыэъё]", w)]; uk = [w for w in ws if re.search("[іїєґ]", w)]
lat = [w for w in ws if re.fullmatch("[a-z']+", w)]
ruLines = [l["text"] for l in L if re.search("[ыэъё]", l["text"].lower()) and not re.search("[іїєґ]", l["text"].lower())]
print(f"words {len(ws)}, ukr-letters {len(uk)}, rus-letters {len(ru)} ({len(ru) / max(1, len(ru) + len(uk)) * 100:.0f}% of marked), latin {len(lat)}; lines {len(L)}, lines that read as Russian {len(ruLines)}; live voices {out['liveVoices']}, after-call {out['offVoices']}")
print("live labels per line:", dict(collections.Counter(l["live"] or "-" for l in L)))
for x in ruLines[:4]: print("   ru?", x[:140])
if len(sys.argv) > 3:
    s0 = float(sys.argv[3]) * 1000
    ev = json.load(open(sys.argv[2]))["events"]
    ref = " ".join("".join(sg.get("utf8", "") for sg in e.get("segs", [])) for e in ev if s0 <= e.get("tStartMs", 0) < s0 + 600000).lower()
    R = re.findall(r"[a-zа-яіїєґёыэъ0-9']+", ref); H = re.findall(r"[a-zа-яіїєґёыэъ0-9']+", text)
    d = list(range(len(H) + 1))
    for i in range(1, len(R) + 1):
        p, d[0] = d[0], i
        for j in range(1, len(H) + 1):
            c = d[j]; d[j] = min(d[j] + 1, d[j - 1] + 1, p + (R[i - 1] != H[j - 1])); p = c
    print(f"vs YouTube auto-captions: ref {len(R)} words, hyp {len(H)}, 'WER' {d[len(H)] / max(1, len(R)) * 100:.0f}% (auto-captions are themselves wrong often)")
