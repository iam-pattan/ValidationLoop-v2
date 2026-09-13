#!/usr/bin/env python3
"""
glm-qc-score.py (v1.5) — Scores one or two LLM-judge outputs against the QC rubric,
computes an analytics-weighted overall confidence, and emits a decision object.

v1.5 ADDITION — goal-aware advisory block: when QC_GOAL_AWARE=1 (set by glm-qc.sh
when a per-session goal log was captured), the scorer ALSO extracts an `alignment`
score and a `deviations` list from each judge object and appends a "GOAL ALIGNMENT"
advisory block to .summary. The 5-dimension weighted .overall and the
PASS/REVIEW/REWORK .verdict are UNCHANGED from v1.4 — alignment is reported, not
folded into the gate. The .summary is byte-identical to v1.4 when QC_GOAL_AWARE=0.
NOTE: the .log object legitimately grew (it now records `goals_captured` and
per-judge `alignment`/`deviations_count` for calibration) — only the gating fields
(.overall/.verdict/.summary) are held invariant, not the full .log schema.

Usage:  glm-qc-score.py <judge1.json> [judge2.json]
Each input file is the RAW text output of a judge (may contain prose/fences;
the JSON object is extracted). Emits a single JSON object on stdout:
  {overall, verdict, summary, log}
verdict in PASS (>=85) | REVIEW (65-84) | REWORK (<65).

Guardrails baked in:
  - Missing dimension/score -> penalized (conservative), never assumed good.
  - Score >=70 without an evidence citation is capped at 65 (no rubber-stamps).
  - Unparseable judge output -> REVIEW with a flag, never a silent PASS.
  - Alignment uses the same uncited-cap; a missing alignment is noted, never
    penalizes the 5-dim score (it is advisory-only).
"""
import sys, re, json, math, os

# Judge labels reflect the model that ACTUALLY ran (the Stop hook may fall back
# from GLM/Kimi to a Claude model when the gateway does not serve them). The hook
# passes the real labels via QC_JUDGE_LABELS as a comma-separated list, in the
# same order as the judge files on argv. Falls back to GLM/Kimi if unset so the
# scorer still works when run standalone.
_LABELS = [s.strip() for s in os.environ.get("QC_JUDGE_LABELS", "").split(",") if s.strip()]

# v1.5: set by glm-qc.sh to 1 when a goal log was captured for this session.
_GOAL_AWARE = os.environ.get("QC_GOAL_AWARE", "0") == "1"

# --- Rubric: analytics-weighted (must sum to 1.0) ---
WEIGHTS = {
    "truthfulness": 0.30,
    "validation":   0.25,
    "authenticity": 0.20,
    "derivations":  0.15,
    "assumptions":  0.10,
}
DIMS = list(WEIGHTS)
PASS_MIN, REVIEW_MIN = 85, 65
MISSING_SCORE = 40      # conservative default when a dimension is absent
UNCITED_CAP  = 65       # a high score with no citation can't exceed this


def extract_json(raw):
    """Pull the first balanced {...} object out of noisy model output."""
    if not raw:
        return None
    raw = raw.strip()
    raw = re.sub(r"^```(?:json)?|```$", "", raw, flags=re.MULTILINE).strip()
    search_from = 0
    while True:
        start = raw.find("{", search_from)
        if start < 0:
            return None
        depth, instr, esc = 0, False, False
        for i in range(start, len(raw)):
            c = raw[i]
            if instr:
                if esc:      esc = False
                elif c == "\\": esc = True
                elif c == '"':  instr = False
            else:
                if c == '"':  instr = True
                elif c == "{": depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        try:
                            return json.loads(raw[start:i + 1])
                        except Exception:
                            break
        # unbalanced or unparsable at this '{' -> keep scanning for the next one
        search_from = start + 1


def score_one(obj):
    """Return (overall, per_dim_detail_list, notes) for one judge object.
    UNCHANGED from v1.4 — alignment is NOT scored here (advisory-only)."""
    dims = (obj or {}).get("dimensions", {}) if isinstance(obj, dict) else {}
    total, details, notes = 0.0, [], []
    for d in DIMS:
        entry = dims.get(d, {}) if isinstance(dims, dict) else {}
        raw_s = entry.get("score") if isinstance(entry, dict) else None
        raw_cite = entry.get("cite") if isinstance(entry, dict) else ""
        cite = raw_cite.strip() if isinstance(raw_cite, str) else ""
        try:
            raw_f = float(raw_s)
            if math.isnan(raw_f) or math.isinf(raw_f):
                raise ValueError("non-finite score")
            s = max(0, min(100, raw_f))
            present = True
        except (TypeError, ValueError):
            s, present = MISSING_SCORE, False
            notes.append(f"{d}: no score -> {MISSING_SCORE}")
        if present and s >= 70 and not cite:
            notes.append(f"{d}: {int(s)} uncited -> capped {UNCITED_CAP}")
            s = min(s, UNCITED_CAP)
        total += s * WEIGHTS[d]
        details.append({"dim": d, "score": round(s, 1), "cite": cite})
    return round(total, 1), details, notes


# --- v1.5: alignment + deviations extraction (advisory-only) ---

def extract_alignment(obj):
    """Return (score, cite, evidence, note) for the alignment field, or None.
    Applies the same uncited-cap as the gated dims; a missing alignment is
    reported as 'no score' and never affects the 5-dim overall."""
    if not isinstance(obj, dict):
        return None
    a = obj.get("alignment")
    if not isinstance(a, dict):
        return None
    raw_s = a.get("score")
    cite = (a.get("cite") or "").strip() if isinstance(a.get("cite"), str) else ""
    evid = (a.get("evidence") or "").strip() if isinstance(a.get("evidence"), str) else ""
    try:
        s = float(raw_s)
        if math.isnan(s) or math.isinf(s):
            raise ValueError
        s = max(0, min(100, s))
        present = True
    except (TypeError, ValueError):
        return {"score": None, "cite": "", "evidence": evid, "note": "alignment: no score"}
    note = ""
    if s >= 70 and not cite:
        note = f"alignment: {int(s)} uncited -> capped {UNCITED_CAP}"
        s = min(s, UNCITED_CAP)
    return {"score": round(s, 1), "cite": cite, "evidence": evid, "note": note}


def extract_deviations(obj):
    """Defensively parse the deviations list. Never fatal."""
    if not isinstance(obj, dict):
        return []
    dev = obj.get("deviations")
    if not isinstance(dev, list):
        return []
    out = []
    for d in dev:
        if not isinstance(d, dict):
            continue
        sev = d.get("severity")
        if not isinstance(sev, str) or sev.lower() not in ("high", "med", "low"):
            sev = "unknown"
        else:
            sev = sev.lower()
        out.append({
            "claimed_goal": str(d.get("claimed_goal", "")).strip(),
            "delivered":    str(d.get("delivered", "")).strip(),
            "severity":     sev,
            "evidence":     (d.get("evidence") or "(uncited)").strip() if isinstance(d.get("evidence"), str) else "(uncited)",
        })
    return out


def verdict_of(overall):
    return "PASS" if overall >= PASS_MIN else ("REVIEW" if overall >= REVIEW_MIN else "REWORK")


def main():
    files = sys.argv[1:]
    judges, parse_flags = [], []
    for i, f in enumerate(files):
        try:
            raw = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            raw = ""
        obj = extract_json(raw)
        if obj is None:
            parse_flags.append(f"judge{i+1} output unparseable")
            judges.append({"overall": REVIEW_MIN, "details": [], "notes": ["unparseable"],
                           "top_issues": ["Judge output could not be parsed as JSON"],
                           "unverified": [], "label": obj_label(i),
                           "alignment": None, "deviations": []})
        else:
            ov, det, notes = score_one(obj)
            judges.append({"overall": ov, "details": det, "notes": notes,
                           "top_issues": obj.get("top_issues", []) if isinstance(obj, dict) else [],
                           "unverified": obj.get("unverified_claims", []) if isinstance(obj, dict) else [],
                           "label": obj_label(i),
                           "alignment": extract_alignment(obj),
                           "deviations": extract_deviations(obj)})

    overalls = [j["overall"] for j in judges]
    if not overalls:
        print(json.dumps({
            "overall": REVIEW_MIN, "verdict": "REVIEW", "disagree": False,
            "summary": "No judge files provided — nothing to score.",
            "log": {"overall": REVIEW_MIN, "verdict": "REVIEW", "judges": [], "disagree": False,
                    "goals_captured": _GOAL_AWARE},
        }))
        return
    final = round(sum(overalls) / len(overalls), 1)
    verdict = verdict_of(final)
    # Flag large disagreement in ensemble
    disagree = len(overalls) > 1 and (max(overalls) - min(overalls) > 20)

    lines = [f"CONFIDENCE: {final}/100  →  VERDICT: {verdict}"]
    lines.append("Weighting: analytics (truthfulness 30 / validation 25 / authenticity 20 / "
                 "derivations 15 / assumptions 10)")
    for j in judges:
        lines.append(f"\n[{j['label']}] overall {j['overall']}")
        for d in j["details"]:
            c = f"  ({d['cite']})" if d["cite"] else "  (no cite)"
            lines.append(f"  - {d['dim']:<13} {int(d['score']):>3}{c}")
        for n in j["notes"]:
            lines.append(f"    · {n}")
        for t in (j["top_issues"] or [])[:5]:
            lines.append(f"  ! {t}")
        for u in (j["unverified"] or [])[:5]:
            lines.append(f"  ? unverified: {u}")

    # --- v1.5: GOAL ALIGNMENT advisory block (only when goals were captured) ---
    any_alignment = any(j["alignment"] for j in judges)
    if _GOAL_AWARE and any_alignment:
        lines.append("\nGOAL ALIGNMENT (advisory — not in the weighted score):")
        for j in judges:
            a = j["alignment"]
            if a is None:
                lines.append(f"  [{j['label']}] alignment: no score")
                continue
            if a["score"] is None:
                lines.append(f"  [{j['label']}] alignment: no score")
                if a["note"]:
                    lines.append(f"    · {a['note']}")
                continue
            c = f"  ({a['cite']})" if a["cite"] else "  (no cite)"
            lines.append(f"  [{j['label']}] alignment {int(a['score']):>3}{c}")
            if a["note"]:
                lines.append(f"    · {a['note']}")
            for d in j["deviations"]:
                lines.append(f"    [{d['severity']}] {d['claimed_goal'] or '(unstated)'} "
                             f"→ {d['delivered'] or '(nothing)'} — {d['evidence']}")
        # If the judge(s) reported no deviations, say so explicitly.
        total_dev = sum(len(j["deviations"]) for j in judges)
        if total_dev == 0:
            lines.append("  no deviations reported")

    if disagree:
        lines.append(f"\n⚠ Judges disagree by {round(max(overalls)-min(overalls),1)} pts — treat as low confidence.")
    if parse_flags:
        lines.append("\n⚠ " + "; ".join(parse_flags))

    out = {
        "overall": final,
        "verdict": verdict,
        "disagree": disagree,
        "summary": "\n".join(lines),
        "log": {"overall": final, "verdict": verdict,
                "judges": [{"label": j["label"], "overall": j["overall"],
                            "dims": {d["dim"]: d["score"] for d in j["details"]},
                            "alignment": (j["alignment"]["score"] if j["alignment"] and j["alignment"]["score"] is not None else None),
                            "deviations_count": len(j["deviations"])} for j in judges],
                "disagree": disagree,
                "goals_captured": _GOAL_AWARE},
    }
    print(json.dumps(out))


def obj_label(i):
    if i < len(_LABELS):
        return _LABELS[i]
    return f"judge {i+1}"


if __name__ == "__main__":
    main()
