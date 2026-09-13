#!/usr/bin/env python3
"""Compare a Parakeet run (JSONL from transcribe_corpus.py) against what
Superwhisper's own speech engine heard (`rawResult` in meta.json, before
any LLM cleanup). Neither side is ground truth; the score is how much the
two engines *disagree*, and the diff list shows where.

usage: score.py <run.jsonl> [--show N] [--fillers] [--only other.jsonl] [--replace replacements.txt]
  --only      score only takes that also appear in other.jsonl (same-takes comparison)
  --fillers   keep um/uh/etc. in the comparison (default: dropped on both
              sides, since Superwhisper strips them and Parakeet keeps them)
"""
import collections, json, os, re, sys
from common import REC, opt, read_jsonl

FILLERS = {"um", "uh", "umm", "uhh", "hmm", "mm", "mhm", "ah", "er"}

run_path = sys.argv[1]
show = opt("--show", 25, int)
keep_fillers = "--fillers" in sys.argv

def norm(s):
    s = s.lower().replace("’", "'")
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    w = s.split()
    if not keep_fillers:
        w = [x for x in w if x not in FILLERS]
    return w

def align(ref, hyp):
    """Levenshtein on word lists; returns (S, D, I, ops) with ops as
    (kind, ref_word, hyp_word)."""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            c = 0 if ref[i - 1] == hyp[j - 1] else 1
            d[i][j] = min(d[i - 1][j - 1] + c, d[i - 1][j] + 1, d[i][j - 1] + 1)
    ops = []; i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (0 if ref[i - 1] == hyp[j - 1] else 1):
            ops.append(("ok" if ref[i - 1] == hyp[j - 1] else "sub", ref[i - 1], hyp[j - 1])); i -= 1; j -= 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", ref[i - 1], None)); i -= 1
        else:
            ops.append(("ins", None, hyp[j - 1])); j -= 1
    ops.reverse()
    S = sum(o[0] == "sub" for o in ops); D = sum(o[0] == "del" for o in ops); I = sum(o[0] == "ins" for o in ops)
    return S, D, I, ops

hyps = {r["id"]: r["text"] for r in read_jsonl(run_path)}
if "--only" in sys.argv:
    keep = {r["id"] for r in read_jsonl(opt("--only", None))}
    hyps = {k: v for k, v in hyps.items() if k in keep}

# Same rules the app applies after transcribing: whole-word, case-insensitive left side.
rules = []
if "--replace" in sys.argv:
    for line in open(os.path.expanduser(opt("--replace", None))):
        t = line.strip()
        if not t or t.startswith("#") or "->" not in t: continue
        a, b = [x.strip() for x in t.split("->", 1)]
        rules.append((re.compile(r"(?<!\w)" + re.escape(a) + r"(?!\w)", re.I), b))
def fix(t):
    for rx, b in rules: t = rx.sub(b, t)
    return t

rows = []; subs = collections.Counter(); dels = collections.Counter(); ins = collections.Counter()
by_model = collections.defaultdict(lambda: [0, 0, 0])   # errs, refwords, takes
for rid, hyp in hyps.items():
    mp = f"{REC}/{rid}/meta.json"
    if not os.path.exists(mp): continue
    m = json.load(open(mp))
    ref = m.get("rawResult") or ""
    if not ref.strip(): continue
    ref, hyp = fix(ref), fix(hyp)   # same spelling rules on both sides, so "Vortex CFD" vs "VortexCFD" isn't an error
    R, H = norm(ref), norm(hyp)
    S, D, I, ops = align(R, H)
    err = S + D + I
    rows.append((err / max(len(R), 1), err, len(R), rid, m.get("modelName"), ref, hyp, ops))
    bm = by_model[m.get("modelName")]; bm[0] += err; bm[1] += len(R); bm[2] += 1
    for k, a, b in ops:
        if k == "sub": subs[(a, b)] += 1
        elif k == "del": dels[a] += 1
        elif k == "ins": ins[b] += 1

tot_err = sum(r[1] for r in rows); tot_ref = sum(r[2] for r in rows)
print(f"takes scored: {len(rows)}   words: {tot_ref}   disagreement (WER-style): {100 * tot_err / max(tot_ref, 1):.1f}%")
for name, (e, w, t) in sorted(by_model.items()):
    print(f"  vs {name:<24} {t:4} takes  {100 * e / max(w, 1):5.1f}%")
exact = sum(1 for r in rows if r[1] == 0)
print(f"  identical takes: {exact}/{len(rows)}   takes under 5%: {sum(1 for r in rows if r[0] < 0.05)}")

print("\nTop substitutions  (superwhisper -> parakeet):")
for (a, b), c in subs.most_common(show): print(f"  {c:3}  {a} -> {b}")
print("\nTop words Parakeet dropped:")
for a, c in dels.most_common(show // 2): print(f"  {c:3}  {a}")
print("\nTop words Parakeet added:")
for b, c in ins.most_common(show // 2): print(f"  {c:3}  {b}")

print("\nWorst takes:")
for wer, err, n, rid, model, ref, hyp, ops in sorted(rows, reverse=True)[:show // 3]:
    print(f"\n-- {rid} ({model}) {100 * wer:.0f}% of {n} words")
    print("  SW: " + ref[:220]); print("  PK: " + hyp[:220])
