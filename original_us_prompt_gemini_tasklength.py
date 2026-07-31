"""
tasklength_sync.py
Runs the tasklength prompt on all O*NET tasks using the standard (non-batch) API.
Uses async concurrency to approach the API rate limits:
  - Token limit:   10,000,000 TPM → ~151 req/sec at ~1,100 tokens/req
  - Request limit: 30,000 RPM → 500 req/sec (not binding)
  - Target:        140 req/sec (7% headroom below token ceiling)
Saves incrementally and resumes from where it left off.
"""

import asyncio
import json
import os
import re
import time
import pandas as pd
from dotenv import load_dotenv
from google import genai
from google.api_core.exceptions import ResourceExhausted, ServiceUnavailable

# ── Config ────────────────────────────────────────────────────────────────────
BASE_DIR    = "/Users/lhampton/MIT Dropbox/Lucy Hampton/It's_about_time"
PROMPT_FILE = os.path.join(BASE_DIR, "code/gemini_duration/tasklength_prompt.md")
TASK_FILE   = os.path.join(BASE_DIR, "data/raw/ONET_29_2.xlsx")
OUTPUT_FILE = os.path.join(BASE_DIR, "data/temp/tasklength_sync.csv")

MODEL_NAME     = "gemini-3-flash-preview"
TARGET_RPS     = 140   # requests per second — stays under 151 token-limit ceiling
MAX_CONCURRENT = 300   # max in-flight requests (140 req/s × ~2s latency = 280 needed)
MAX_RETRIES    = 3
RETRY_WAIT_SEC = 10
N_SAMPLES      = 5     # prompt repetitions per task — numeric fields are averaged

# ── Load credentials ──────────────────────────────────────────────────────────
load_dotenv(os.path.join(BASE_DIR, ".env"))
api_key = os.environ.get("GOOGLE_API_KEY")
if not api_key:
    raise EnvironmentError("GOOGLE_API_KEY not found in .env or environment.")

client = genai.Client(api_key=api_key)

# ── Load prompt template ──────────────────────────────────────────────────────
with open(PROMPT_FILE, "r") as f:
    prompt_template = f.read()

# ── Load tasks ────────────────────────────────────────────────────────────────
tasks = pd.read_excel(TASK_FILE, sheet_name="Task Statements")
pool = tasks[["O*NET-SOC Code", "Title", "Task"]].dropna().reset_index(drop=True)
print(f"Total tasks: {len(pool)}")

# ── Resume: skip already-completed tasks ──────────────────────────────────────
if os.path.exists(OUTPUT_FILE):
    done = pd.read_csv(OUTPUT_FILE)
    done_tasks = set(zip(done["soc_code"], done["task"]))
    print(f"Resuming — {len(done_tasks)} done, {len(pool) - len(done_tasks)} remaining.")
else:
    done_tasks = set()
    print("Starting fresh.")

pool_remaining = pool[
    ~pool.apply(lambda r: (r["O*NET-SOC Code"], r["Task"]) in done_tasks, axis=1)
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
    soc_code         = row["O*NET-SOC Code"]
    occupation_title = row["Title"]
    task_description = row["Task"]

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
                        model=MODEL_NAME, contents=prompt
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
