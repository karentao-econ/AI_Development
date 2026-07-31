"""
filterautomation_run.py
Applies the AI-exposure taxonomy in filterautomation.py to every task in a task CSV,
using gemini-3-flash-preview on Vertex AI.


Output CSV: task_id, occupation_code, occupation_name, task,
            llme, llmte, llmme, *_reasoning, overall, consistency_note

    python filterautomation_run.py --limit 25 --out pilot.csv        # pilot
    python filterautomation_run.py                                   # full sweep
"""

import argparse
import csv
import os
import re
import threading
import time

import pandas as pd
from dotenv import load_dotenv
from google import genai
from google.genai import types
from google.genai import errors as genai_errors

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROMPT_FILE = os.path.join(BASE_DIR, "filterautomation.py")
DEFAULT_IN = ("/Users/karentao/MIT Dropbox/Karen Tao/AI_and_Development_MIT_FutureTech/"
              "Karen/00 Code/AI_Development/Tasks/nco_2015_tasks_gemini.csv")
DEFAULT_OUT = os.path.join(BASE_DIR, "nco_2015_ai_exposure.csv")

PROJECT  = os.environ.get("GOOGLE_CLOUD_PROJECT", "project-883bd60a-d828-4717-af3")
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "global")
MODEL    = os.environ.get("EXPOSURE_MODEL", "gemini-3-flash-preview")

MAX_CONCURRENT = int(os.environ.get("EXPOSURE_CONCURRENCY", "8"))
MAX_RETRIES    = 5
MAX_OUTPUT_TOKENS = 8192
THINKING_LEVEL    = "low"

OUT_COLS = ["task_id", "occupation_code", "occupation_name", "task",
            "llme", "llmte", "llmme",
            "llme_reasoning", "llmte_reasoning", "llmme_reasoning",
            "consistency_note", "overall", "error"]

LEVELS = ["0", "1", "2", "3", "4"]
EXPOSURE_SCHEMA = {
    "type": "object",
    "properties": {
        "llme_reasoning":  {"type": "string"},
        "llme_label":      {"type": "string", "enum": [f"LLME{i}" for i in LEVELS]},
        "llmte_reasoning": {"type": "string"},
        "llmte_label":     {"type": "string", "enum": [f"LLMTE{i}" for i in LEVELS]},
        "llmme_reasoning": {"type": "string"},
        "llmme_label":     {"type": "string", "enum": [f"LLMME{i}" for i in LEVELS]},
        "consistency_note": {"type": "string"},
        "overall":          {"type": "string"},
    },
    "required": ["llme_reasoning", "llme_label", "llmte_reasoning", "llmte_label",
                 "llmme_reasoning", "llmme_label", "consistency_note", "overall"],
}


def load_prompts():
    """Source both prompts from filterautomation.py without duplicating their text.

    That file cannot be imported directly (NameError at line 159). Executing it with
    `occupation`/`task` pre-bound to their own placeholder braces makes the f-string
    evaluate into a reusable .format() template, so the exact wording is preserved.
    """
    ns = {"occupation": "{occupation}", "task": "{task}"}
    with open(PROMPT_FILE) as fh:
        exec(fh.read(), ns)
    return ns["system_prompt"], ns["user_prompt"]


SYSTEM_PROMPT, USER_TEMPLATE = load_prompts()

load_dotenv(os.path.join(BASE_DIR, ".env"))
if not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
    raise EnvironmentError("GOOGLE_APPLICATION_CREDENTIALS not set.")
client = genai.Client(vertexai=True, project=PROJECT, location=LOCATION)

_slots = threading.Semaphore(MAX_CONCURRENT)
_file_lock = threading.Lock()
_counter = [0, 0.0, 0]          # [done, start_time, errors]


def classify(occupation, task):
    """One Vertex call. Returns the parsed dict, or raises after MAX_RETRIES."""
    prompt = USER_TEMPLATE.format(occupation=occupation, task=task)
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            with _slots:
                resp = client.models.generate_content(
                    model=MODEL,
                    contents=prompt,
                    config=types.GenerateContentConfig(
                        system_instruction=SYSTEM_PROMPT,
                        response_mime_type="application/json",
                        response_schema=EXPOSURE_SCHEMA,
                        temperature=0,
                        max_output_tokens=MAX_OUTPUT_TOKENS,
                        thinking_config=types.ThinkingConfig(thinking_level=THINKING_LEVEL),
                    ),
                )
            fr = str(getattr(resp.candidates[0], "finish_reason", ""))
            if "MAX_TOKENS" in fr:
                raise RuntimeError(f"truncated at max_output_tokens={MAX_OUTPUT_TOKENS}")
            import json
            return json.loads(resp.text or "{}")

        # google-genai raises ClientError, never google.api_core ResourceExhausted.
        except genai_errors.ClientError as e:
            if getattr(e, "code", None) != 429 or attempt == MAX_RETRIES:
                raise
            time.sleep(2 ** attempt)
        except genai_errors.ServerError:
            if attempt == MAX_RETRIES:
                raise
            time.sleep(2 ** attempt)
    raise RuntimeError("retries exhausted")


_LVL = re.compile(r"(\d)$")


def level(label):
    m = _LVL.search(label or "")
    return int(m.group(1)) if m else None


def process_row(row, out_path, total):
    rec = {c: None for c in OUT_COLS}
    rec.update({"task_id": row.task_id, "occupation_code": row.occupation_code,
                "occupation_name": row.occupation_name, "task": row.task})
    try:
        r = classify(row.occupation_name, row.task)
        rec.update({
            "llme": r["llme_label"], "llmte": r["llmte_label"], "llmme": r["llmme_label"],
            "llme_reasoning": r["llme_reasoning"], "llmte_reasoning": r["llmte_reasoning"],
            "llmme_reasoning": r["llmme_reasoning"],
            "consistency_note": r["consistency_note"], "overall": r["overall"],
        })
        # The taxonomy requires LLMME >= LLME (multimodal is a superset of text-only).
        # The model is asked to self-check, but record violations rather than trust it.
        a, b = level(r["llme_label"]), level(r["llmme_label"])
        if a is not None and b is not None and b < a:
            rec["error"] = f"consistency_violation LLMME{b}<LLME{a}"
    except Exception as exc:
        rec["error"] = f"{type(exc).__name__}: {str(exc)[:120]}"
        _counter[2] += 1

    with _file_lock:
        new = not os.path.exists(out_path) or os.path.getsize(out_path) == 0
        with open(out_path, "a", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=OUT_COLS)
            if new:
                w.writeheader()
            w.writerow(rec)
        _counter[0] += 1
        n = _counter[0]
    if n % 25 == 0 or n == total:
        el = (time.time() - _counter[1]) / 60
        rate = n / el if el else 0
        print(f"  [{n}/{total}] {el:.0f} min, {rate:.0f} tasks/min, "
              f"ETA {(total - n) / rate if rate else 0:.0f} min, {_counter[2]} errors")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", default=DEFAULT_IN)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--limit", type=int, help="pilot: only the first N unprocessed tasks")
    args = ap.parse_args()

    pool = pd.read_csv(args.src, dtype={"occupation_code": str})
    print(f"{len(pool):,} tasks in {os.path.basename(args.src)}")

    # Resume on task_id; only rows that produced a label count as done.
    done = set()
    if os.path.exists(args.out) and os.path.getsize(args.out) > 0:
        # dtype MUST be str: NCO codes like "1111.0100" parse as the float 1111.01,
        # and the rewrite below then persists that, silently destroying trailing zeros
        # across the whole file. Same trap as the resume in the tasklength scripts.
        prev = pd.read_csv(args.out, dtype={"occupation_code": str})
        done = set(prev.loc[prev["llme"].notna(), "task_id"])
        keep = prev[prev["llme"].notna()]
        keep.to_csv(args.out, index=False)   # drop failed rows so they re-run
        print(f"resuming — {len(done):,} done, {len(prev) - len(keep):,} failed rows re-queued")

    todo = pool[~pool["task_id"].isin(done)]
    if args.limit:
        todo = todo.head(args.limit)
    total = len(todo)
    print(f"to process: {total:,} on {MODEL} @ {MAX_CONCURRENT} concurrent")
    if not total:
        return

    _counter[1] = time.time()
    from concurrent.futures import ThreadPoolExecutor, as_completed
    with ThreadPoolExecutor(MAX_CONCURRENT) as ex:
        futs = [ex.submit(process_row, r, args.out, total) for r in todo.itertuples()]
        for f in as_completed(futs):
            f.result()

    d = pd.read_csv(args.out)
    ok = d[d["llme"].notna()]
    print(f"\n{len(ok):,}/{len(pool):,} tasks labelled | {d['error'].notna().sum():,} errors")
    for dim in ("llme", "llmte", "llmme"):
        counts = ok[dim].value_counts().sort_index().to_dict()
        print(f"  {dim.upper():6} {counts}")
    viol = d["error"].astype(str).str.contains("consistency_violation").sum()
    print(f"  LLMME<LLME violations: {viol}")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
