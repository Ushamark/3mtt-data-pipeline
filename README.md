# 3MTT Fellows Cohort Cleaning Pipeline

## What it does
Ingests `fellows_cohort.csv`, applies cleaning (deduplication, state normalisation, phone standardisation, enrollment date parsing), quarantines malformed rows, and emits a clean CSV alongside a structured JSON run-log (timestamp, rows in/out, issues found, processing time).

## How to run
```bash
python automate_pipeline.py --input /path/to/fellows_cohort.csv --output outputs/fellows_clean.csv
```

## Idempotency proof
Run the script twice on the same input — the output file MD5 (`output_md5` in the log) will be identical both times, confirming no duplication or drift.

## Graceful error handling
Feed it a file with a malformed row (e.g. a fellow_id of `BADROW`) — the script prints a structured `[WARN]` message to stderr, quarantines that row, continues processing the rest, and exits with code 0. A truly unreadable file (missing columns, unparseable CSV) exits with code 1 and a clean JSON error log — no raw Python traceback.

## What it outputs
- `outputs/fellows_clean.csv` — deduplicated, normalised CSV
- JSON run-log to stdout — pipe to a file or logging system as needed

## Scheduling design note
**Recommended approach: GitHub Actions scheduled workflow (`cron`)**

```yaml
# .github/workflows/pipeline.yml
on:
  schedule:
    - cron: '0 6 * * 1'   # Every Monday at 06:00 UTC
  workflow_dispatch:        # Allow manual trigger
```

**Trade-offs vs alternatives:**
| Option | Pros | Cons |
|---|---|---|
| GitHub Actions | Free, version-controlled, audit trail, no server | Cold start ~30s; requires repo |
| Cron on VM | Full control, fast | Server cost, no built-in alerting |
| Apache Airflow | DAG dependencies, retry logic, monitoring UI | Overkill for a single script; infra overhead |
| Apps Script trigger | No infra, Google ecosystem | Limited to Google Workspace data; Python not native |

For 3MTT's scale (weekly CSV drops), **GitHub Actions** is the right balance of simplicity, auditability, and zero infrastructure cost. Upgrade to Airflow only when the pipeline grows to 5+ dependent tasks.
