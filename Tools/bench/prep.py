# prep.py <words glob> <wav> <out prefix>: picks the 10 minutes where the most people speak (then the most evenly), writes <prefix>.ref.json, <prefix>.wav, prints the offset
import re, glob, json, sys, subprocess
W = []
for f in sorted(glob.glob(sys.argv[1])):
    spk = f.split("/")[-1].split(".")[1]
    for m in re.finditer(r'<w [^>]*starttime="([\d.]+)" endtime="([\d.]+)"[^>]*>([^<]*)</w>', open(f, encoding="latin-1").read()):
        W.append((float(m[1]), float(m[2]), spk, m[3]))
W.sort()
end = W[-1][1]
best = None
for s in range(0, max(1, int(end) - 600), 30):
    c = {}
    for w in W:
        if s <= w[0] < s + 600: c[w[2]] = c.get(w[2], 0) + 1
    act = [v for v in c.values() if v >= 40]
    sc = (len(act), min(act) if act else 0)
    if not best or sc > best[0]: best = (sc, s, c)
s = best[1]
json.dump([w for w in W if s <= w[0] < s + 600], open(sys.argv[3] + ".ref.json", "w"))
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", str(s), "-t", "600", "-i", sys.argv[2], "-ar", "16000", "-ac", "1", sys.argv[3] + ".wav"], check=True)
print(s, best[2])
