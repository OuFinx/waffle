"""Downloads the first N recordings of a FLEURS language (dev set) with their transcripts: python fetch.py uk_ua 80"""
import sys, tarfile, urllib.request, os, csv, io
lang, n = sys.argv[1], int(sys.argv[2])
base = f"https://huggingface.co/datasets/google/fleurs/resolve/main/data/{lang}"
out = os.path.join(os.environ.get("WAFFLE_EVAL", "/tmp/waffle-eval"), "data", lang); os.makedirs(out, exist_ok=True)
tsv = urllib.request.urlopen(f"{base}/dev.tsv").read().decode()
rows = {}
for line in tsv.splitlines():
    p = line.split("\t")
    if len(p) >= 7: rows[p[1]] = (p[0], p[2], p[3], p[6])  # id, raw transcription, normalized, gender
got = 0
with urllib.request.urlopen(f"{base}/audio/dev.tar.gz") as r:
    with tarfile.open(fileobj=r, mode="r|gz") as t:
        for m in t:
            if not m.isfile(): continue
            name = os.path.basename(m.name)
            if name not in rows: continue
            data = t.extractfile(m).read()
            open(f"{out}/{name}", "wb").write(data)
            sid, raw, norm, gender = rows[name]
            with open(f"{out}/refs.tsv", "a") as f: f.write(f"{name}\t{sid}\t{gender}\t{raw}\n")
            got += 1
            if got >= n: break
print(lang, got)
