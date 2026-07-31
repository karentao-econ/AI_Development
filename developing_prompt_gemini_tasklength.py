"""
developing_prompt_gemini_tasklength.py
Runs the tasklength prompt on all Indonesia tasks using Vertex AI (non-batch).
Uses async concurrency to approach the API rate limits:
  - Token limit:   10,000,000 TPM → ~151 req/sec at ~1,100 tokens/req
  - Request limit: 30,000 RPM → 500 req/sec (not binding)
  - Target:        140 req/sec (7% headroom below token ceiling)
Saves incrementally and resumes from where it left off.

Auth: set GOOGLE_APPLICATION_CREDENTIALS to the service-account key JSON
(in .env or the environment). The service account needs roles/aiplatform.user
and the Vertex AI API enabled on the project.
"""

import asyncio
import json
import os
import re
import time
import pandas as pd
from dotenv import load_dotenv
from google import genai
from google.genai import types
from google.api_core.exceptions import ResourceExhausted, ServiceUnavailable

# ── Config ────────────────────────────────────────────────────────────────────
BASE_DIR    = "/Users/karentao/MIT Dropbox/Karen Tao/AI_and_Development_MIT_FutureTech/Karen/05 Task Length Exercise"
PROMPT_FILE = os.path.join(BASE_DIR, "tasklength_prompt.md")
TASK_FILE   = os.environ.get("TASKLENGTH_INPUT",
                            os.path.join(BASE_DIR, "indonesia_2020_tasks.csv"))
OUTPUT_FILE = os.environ.get("TASKLENGTH_OUTPUT",
                            os.path.join(BASE_DIR, "tasklength_developing.csv"))

MODEL_NAME     = "gemini-3-flash-preview"
# Tuned for Vertex, not for a paid Developer-API key. At 300 concurrent Vertex
# throttles; those 429s arrive as google.genai.errors.ClientError, which the
# api_core handlers below do not catch, so the draw is silently dropped — the
# first run at 300/140 averaged only 3.29 of 5 draws per task. These values ran
# 1,179 requests on this project with zero 429s.
TARGET_RPS     = float(os.environ.get("TASKLENGTH_RPS", "1"))     # req/sec
MAX_CONCURRENT = int(os.environ.get("TASKLENGTH_CONCURRENCY", "8"))
MAX_RETRIES    = 3
RETRY_WAIT_SEC = 10
N_SAMPLES      = 5     # prompt repetitions per task — numeric fields are averaged

# Vertex AI project/location. gemini-3-flash-preview is served in "global";
# us-central1 returns 404 for this model.
VERTEX_PROJECT  = os.environ.get("GOOGLE_CLOUD_PROJECT", "project-883bd60a-d828-4717-af3")
VERTEX_LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "global")

# Forcing the response shape removes the only failure path in this script that gave up
# without retrying: `except json.JSONDecodeError: break` abandoned a draw whenever the
# model emitted unparseable JSON, which cost ~0.13% of requests (10 lost draws in 7,840)
# and left rows averaged over 4 draws instead of 5. The enums also stop duration_units
# drifting outside the set _UNIT_TO_HOURS knows how to convert.
TASKLENGTH_SCHEMA = {
    "type": "object",
    "properties": {
        "duration":       {"type": "number"},
        "duration_units": {"type": "string", "enum": ["minutes", "hours", "days", "weeks"]},
        "ci_lower":       {"type": "number"},
        "ci_upper":       {"type": "number"},
        "confidence":     {"type": "string", "enum": ["low", "medium", "high"]},
        "justification":  {"type": "string"},
    },
    "required": ["duration", "duration_units", "ci_lower", "ci_upper",
                 "confidence", "justification"],
}

# NOTE: temperature is deliberately NOT set. The 5 draws per task are only meaningful
# because sampling varies between them; pinning temperature=0 would make all 5 identical
# and silently turn the average into a single draw.
GEN_CONFIG = types.GenerateContentConfig(
    response_mime_type="application/json",
    response_schema=TASKLENGTH_SCHEMA,
)


# ── Load credentials ──────────────────────────────────────────────────────────
load_dotenv(os.path.join(BASE_DIR, ".env"))
if not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
    raise EnvironmentError("GOOGLE_APPLICATION_CREDENTIALS not found in .env or environment.")

client = genai.Client(vertexai=True, project=VERTEX_PROJECT, location=VERTEX_LOCATION)

# ── Load prompt template ──────────────────────────────────────────────────────
with open(PROMPT_FILE, "r") as f:
    prompt_template = f.read()

# ── Load tasks ────────────────────────────────────────────────────────────────
tasks = pd.read_csv(TASK_FILE, dtype={"occupation_code": str})
pool = tasks[["occupation_code", "title", "task"]].dropna().reset_index(drop=True)
print(f"Total tasks: {len(pool)}")

# ── Resume: skip already-completed tasks ──────────────────────────────────────
if os.path.exists(OUTPUT_FILE):
    # soc_code MUST be read as str: Indonesian codes are pure digits, so pandas
    # types them as int64 on read-back while the source keeps them as strings.
    # ("1219", task) != (1219, task), so the resume set silently matches nothing
    # and every task is re-queued and appended as a duplicate. (The O*NET version
    # is immune only because SOC codes like "11-1011.00" stay strings.)
    done = pd.read_csv(OUTPUT_FILE, dtype={"soc_code": str})
    # Only rows with the full N_SAMPLES draws count as done. A task averaged over
    # two draws is far noisier than one averaged over five, and keying resume on
    # row presence alone would lock that in permanently — a re-run would skip it.
    # Short rows are dropped from the file and re-queued, so re-running fills its
    # own gaps. (Dropping them also prevents a duplicate row being appended.)
    keep = done[done["n_samples"].fillna(0) >= N_SAMPLES]
    n_requeued = len(done) - len(keep)
    keep.to_csv(OUTPUT_FILE, index=False)
    done_tasks = set(zip(keep["soc_code"], keep["task"]))
    print(f"Resuming — {len(done_tasks)} done, {n_requeued} short rows re-queued, "
          f"{len(pool) - len(done_tasks)} remaining.")
else:
    done_tasks = set()
    print("Starting fresh.")

pool_remaining = pool[
    ~pool.apply(lambda r: (r["occupation_code"], r["task"]) in done_tasks, axis=1)
].reset_index(drop=True)
print(f"Tasks to process: {len(pool_remaining)}")

# ── Token-bucket rate limiter ─────────────────────────────────────────────────
class RateLimiter:
    """Allows up to `rate` calls per second using a token bucket."""
    def __init__(self, rate):
        self._rate = rate
        self._tokens = float(rate)
        self._last = None
        self._lock = asyncio.Lock()

    async def acquire(self):
        async with self._lock:
            now = asyncio.get_event_loop().time()
            if self._last is None:
                self._last = now
            self._tokens = min(self._rate, self._tokens + (now - self._last) * self._rate)
            self._last = now
            if self._tokens < 1:
                wait = (1 - self._tokens) / self._rate
                await asyncio.sleep(wait)
                self._tokens = 0
            else:
                self._tokens -= 1

# ── Unit conversion ───────────────────────────────────────────────────────────
_UNIT_TO_HOURS = {
    "second": 1 / 3600, "seconds": 1 / 3600,
    "minute": 1 / 60,   "minutes": 1 / 60,
    "hour":   1,        "hours":   1,
    "day":    24,        "days":    24,
    "week":   168,       "weeks":   168,
}

def _to_hours(value, units):
    if not isinstance(value, (int, float)):
        return None
    factor = _UNIT_TO_HOURS.get(str(units).lower().strip()) if units else None
    return value * factor if factor is not None else None

# ── Async worker ──────────────────────────────────────────────────────────────
async def process_task(row, semaphore, rate_limiter, file_lock, write_header, counter, total):
    soc_code         = row["occupation_code"]
    occupation_title = row["title"]
    task_description = row["task"]

    prompt = prompt_template.replace("{occupation_title}", occupation_title)
    prompt = prompt.replace("{SOC_code}", soc_code)
    prompt = prompt.replace("{task_description}", task_description)

    parsed_results = []

    async with semaphore:
        for _ in range(N_SAMPLES):
            for attempt in range(1, MAX_RETRIES + 1):
                await rate_limiter.acquire()
                try:
                    response = await client.aio.models.generate_content(
                        model=MODEL_NAME, contents=prompt, config=GEN_CONFIG
                    )
                    raw = response.text.strip()
                    raw_clean = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw, flags=re.MULTILINE).strip()
                    raw_clean = re.sub(r",\s*(\}|\])", r"\1", raw_clean)
                    parsed = json.loads(raw_clean)
                    parsed_results.append(parsed)
                    break  # success — move to next sample

                except (ResourceExhausted, ServiceUnavailable):
                    if attempt < MAX_RETRIES:
                        await asyncio.sleep(RETRY_WAIT_SEC * attempt)

                except json.JSONDecodeError:
                    break  # bad JSON — skip this sample, don't retry

                except Exception:
                    if attempt < MAX_RETRIES:
                        await asyncio.sleep(RETRY_WAIT_SEC)

    # Aggregate across samples — convert each to hours then average
    def _mean_hours(key):
        vals = [_to_hours(r.get(key), r.get("duration_units")) for r in parsed_results]
        vals = [v for v in vals if v is not None]
        return sum(vals) / len(vals) if vals else None

    n_ok = len(parsed_results)
    if n_ok > 0:
        duration       = _mean_hours("duration")
        duration_units = "hours"
    else:
        duration = duration_units = None

    # Write result
    result = pd.DataFrame([{
        "soc_code":         soc_code,
        "occupation_title": occupation_title,
        "task":             task_description,
        "duration":         duration,
        "duration_units":   duration_units,
        "n_samples":        n_ok,
    }])

    async with file_lock:
        result.to_csv(OUTPUT_FILE, mode="a", header=write_header[0], index=False)
        write_header[0] = False

    n = counter[0] = counter[0] + 1
    if n % 500 == 0 or n == total:
        elapsed = time.time() - counter[1]
        print(f"  [{n}/{total}] {n/elapsed:.1f} tasks/s elapsed ({n*N_SAMPLES/elapsed:.1f} req/s)")

# ── Main ──────────────────────────────────────────────────────────────────────
async def main():
    semaphore    = asyncio.Semaphore(MAX_CONCURRENT)
    rate_limiter = RateLimiter(TARGET_RPS)
    file_lock    = asyncio.Lock()
    write_header = [not os.path.exists(OUTPUT_FILE)]
    total        = len(pool_remaining)
    counter      = [0, time.time()]   # [count, start_time]

    print(f"Targeting {TARGET_RPS} req/s with {MAX_CONCURRENT} concurrent workers ({N_SAMPLES} samples/task).")
    print(f"Estimated completion: {total * N_SAMPLES / TARGET_RPS / 60:.1f} minutes\n")

    tasks_coros = [
        process_task(
            pool_remaining.iloc[i], semaphore, rate_limiter,
            file_lock, write_header, counter, total
        )
        for i in range(total)
    ]
    await asyncio.gather(*tasks_coros)
    print(f"\nDone. Results saved to {OUTPUT_FILE}")

if __name__ == "__main__":
    asyncio.run(main())
