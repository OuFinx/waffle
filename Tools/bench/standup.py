# standup.py <n people> <out prefix> [seed] (ICSI headset mixes <meeting>.wav and the NXT annotations in $ICSI_DIR/nxt/ICSI): a stand-up of n people built from ICSI: a host, then each person talks once (25-45 s of their own
# speech with nobody else talking), the host says a few words between turns. Writes <prefix>.wav (16 kHz) and <prefix>.ref.json
# [start, end, participant, word]; offset 0.
import re, glob, json, os, sys, random, subprocess, wave, struct
N, out = int(sys.argv[1]), sys.argv[2]
random.seed(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
D = os.environ["ICSI_DIR"]
meetings = sorted({f.split("/")[-1][:-4] for f in glob.glob(D + "/B*.wav")})
spans = {}  # participant -> [(meeting, start, end, words)]
for m in meetings:
    words, who = [], {}
    for f in glob.glob(f"{D}/nxt/ICSI/Segments/{m}.*.segs.xml"):
        p = re.search(r'participant="([^"]+)"', open(f, encoding="latin-1").read())
        if p: who[f.split(".")[-3]] = p[1]
    for f in glob.glob(f"{D}/nxt/ICSI/Words/{m}.*.words.xml"):
        ch = f.split(".")[-3]
        for x in re.finditer(r'<w [^>]*starttime="([\d.]+)" endtime="([\d.]+)"[^>]*>([^<]*)</w>', open(f, encoding="latin-1").read()):
            words.append((float(x[1]), float(x[2]), who.get(ch, m + ch), x[3]))
    words.sort()
    i = 0
    while i < len(words):  # runs of one speaker, gaps under 1.2 s, nobody else within 0.7 s
        j = i
        while j + 1 < len(words) and words[j + 1][2] == words[i][2] and words[j + 1][0] - words[j][1] < 1.2: j += 1
        s, e, p = words[i][0], words[j][1], words[i][2]
        clean = not any(w[2] != p and w[1] > s - 0.7 and w[0] < e + 0.7 for w in words[max(0, i - 40):j + 40])
        if clean and e - s >= 3: spans.setdefault(p, []).append((m, s, e, words[i:j + 1]))
        i = j + 1
long = {p: sorted([x for x in v if 12 <= x[2] - x[1] <= 45], key=lambda x: -(x[2] - x[1])) for p, v in spans.items()}
people = [p for p in long if sum(x[2] - x[1] for x in long[p][:3]) >= 25]
short = {p: [x for x in v if 2.5 <= x[2] - x[1] <= 7] for p, v in spans.items()}
host = max((p for p in people if len(short[p]) >= N), key=lambda p: len(short[p]))
others = random.sample([p for p in people if p != host], N - 1)
print(f"{len(people)} people with enough clean speech; host {host}, others {others}", file=sys.stderr)
def cut(m, s, e):
    r = subprocess.run(["ffmpeg", "-loglevel", "error", "-ss", str(s), "-t", str(e - s), "-i", f"{D}/{m}.wav", "-f", "s16le", "-ar", "16000", "-ac", "1", "-"], capture_output=True, check=True).stdout
    return list(struct.unpack(f"<{len(r) // 2}h", r))
pcm, ref = [], []
def add(x, gap):
    m, s, e, ws = x
    t0 = len(pcm) / 16000
    pcm.extend(cut(m, s - 0.2, e + 0.3))
    ref.extend((t0 + w[0] - s + 0.2, t0 + w[1] - s + 0.2, w[2], w[3]) for w in ws)
    pcm.extend(random.randint(-3, 3) for _ in range(int(gap * 16000)))
hs = random.sample(short[host], N)
add(hs[0], 0.8)
for k, p in enumerate(others):
    total = 0
    for x in long[p]:
        if total >= 25: break
        add(x, random.uniform(0.3, 0.9)); total += x[2] - x[1]
    add(hs[k + 1], random.uniform(0.6, 1.2))
with wave.open(out + ".wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(struct.pack(f"<{len(pcm)}h", *pcm))
json.dump(ref, open(out + ".ref.json", "w"))
open(out + ".off", "w").write("0 {}\n")
print(f"{len(pcm) / 16000 / 60:.1f} min, {len({r[2] for r in ref})} speakers, {len(ref)} words", file=sys.stderr)
