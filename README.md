# 3MTT Data Cleaning Pipeline

A command-line Python script that ingests any of the four 3MTT source files,
applies cleaning, deduplication, and phone standardisation, and emits a
structured JSON run-log recording rows in, rows out, issues found, and
processing time.

---

## What it does

| Step | Action |
|------|--------|
| Load | Reads `.csv` or `.xlsx`; auto-detects the merged Excel title row in `reflection_survey.xlsx` and applies `skiprows=1` |
| Detect | Auto-identifies which of the four 3MTT file types it received from column names; overridable with `--file-type` |
| Clean | Applies file-specific cleaning: state normalisation, phone standardisation to `234XXXXXXXXXX`, duplicate removal, out-of-range value exclusion, ALC code tagging |
| Idempotency | MD5-hashes the input file; if the exact same file was already processed, skips and logs `skipped_duplicate` — **run it twice, get one output** |
| Error handling | Missing file, bad extension, unrecognisable columns, and unexpected errors all produce a clean `log.error(...)` message, not a raw Python traceback |
| Log | Writes a timestamped `run_log_<id>.json` with all metadata; also prints it to stdout |

---

## Requirements

```
Python 3.10+
pandas
openpyxl      # for .xlsx support
```

Install:
```bash
pip install pandas openpyxl
```

---

## How to run

```bash
# Basic — auto-detects file type, outputs to ./output/
python 3mtt_pipeline.py --input data/fellows_cohort.csv

# Specify output directory
python 3mtt_pipeline.py --input data/reflection_survey.xlsx --output-dir /tmp/cleaned

# Override file-type detection
python 3mtt_pipeline.py --input data/myfile.csv --file-type alc_weekly_log

# Run on all four files
for f in fellows_cohort.csv alc_weekly_log.csv reflection_survey.xlsx employer_engagement.csv; do
    python 3mtt_pipeline.py --input data/$f --output-dir output/
done
```

---

## What it outputs

```
output/
├── fellows_cohort_cleaned_20260518T120000Z.csv   ← cleaned data
├── run_log_20260518T120000Z.json                 ← structured run-log
└── .processed_hashes.json                        ← idempotency index
```

**Sample run-log:**
```json
{
  "run_id": "20260518T120000Z",
  "timestamp_utc": "2026-05-18T12:00:00+00:00",
  "input_file": "data/fellows_cohort.csv",
  "input_hash_md5": "a3f9e2...",
  "file_type": "fellows_cohort",
  "rows_in": 1175,
  "rows_out": 1150,
  "issues_found": [
    "State normalisation: 103 variants → 37",
    "NULL alc_code: 47 rows tagged 'ALC-UNKNOWN'",
    "Exact duplicate rows removed: 20",
    "Partial duplicate fellow_ids resolved: 5 (kept earliest enrollment)"
  ],
  "output_file": "output/fellows_cohort_cleaned_20260518T120000Z.csv",
  "processing_time_s": 0.412,
  "status": "success"
}
```

---

## Idempotency — how it works

The script computes an **MD5 hash of the input file** before processing.
It stores all processed hashes in `output/.processed_hashes.json`.
On a second run with the same input file, it detects the hash match,
logs `skipped_duplicate`, and writes no new output file.

```bash
# Run 1 — processes and writes output
python 3mtt_pipeline.py --input data/fellows_cohort.csv

# Run 2 — detects same file, skips cleanly
python 3mtt_pipeline.py --input data/fellows_cohort.csv
# → WARNING  IDEMPOTENCY: This exact input file was already processed.
```

To force a rerun (e.g. after upstream data changes): delete
`output/.processed_hashes.json` or the specific entry for that file.

---

## Graceful error handling

| Scenario | Behaviour |
|----------|-----------|
| File not found | `ERROR: Input file not found: ...` → exit code 1 |
| Bad extension (e.g. `.json`) | `ERROR: Unsupported file extension...` → exit code 1 |
| Unrecognisable columns | `ERROR: Cannot detect file type...` + hint to use `--file-type` → exit code 2 |
| Unexpected runtime error | Clean `ERROR: type: message` → exit code 3 (set `PYTHONTRACEBACK=1` for full trace) |

**Demonstrating error handling:**
```bash
# Bad file path
python 3mtt_pipeline.py --input data/does_not_exist.csv
# → ERROR    Input file not found: data/does_not_exist.csv

# Unsupported extension
python 3mtt_pipeline.py --input data/something.json
# → ERROR    Unsupported file extension: '.json'

# File with wrong/unrecognisable columns
python 3mtt_pipeline.py --input data/random.csv
# → ERROR    Cannot detect file type from columns: [...]
#            Pass --file-type explicitly.
```

---

## Scheduling design — deploying to run weekly in production

### Recommended: GitHub Actions (chosen approach)

```yaml
# .github/workflows/weekly_pipeline.yml
name: 3MTT Weekly Data Pipeline
on:
  schedule:
    - cron: "0 6 * * 1"    # Every Monday at 06:00 UTC
  workflow_dispatch:         # Also allow manual trigger

jobs:
  run-pipeline:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install pandas openpyxl
      - run: |
          for f in data/*.csv data/*.xlsx; do
            python 3mtt_pipeline.py --input "$f" --output-dir output/
          done
      - uses: actions/upload-artifact@v4
        with:
          name: cleaned-outputs-${{ github.run_id }}
          path: output/
```

**Why GitHub Actions:**
- Zero infrastructure cost for this workload (free tier: 2,000 min/month)
- Run-logs are stored as downloadable workflow artifacts — full audit trail
- `workflow_dispatch` lets programme staff trigger manually outside the schedule
- Built-in secret management for any credentials (Google Drive, email alerts)
- Version-controlled — the schedule and the code are in the same repo

**Trade-offs vs alternatives:**

| Option | Pro | Con |
|--------|-----|-----|
| **GitHub Actions** ✓ | Free, auditable, no server | Requires internet; 6-hr job limit |
| **Cron (Linux server)** | Simple, offline-capable | Requires always-on server; no UI |
| **Cloud Scheduler (GCP)** | Managed, scalable | Cost; GCP dependency |
| **Airflow** | Full DAG orchestration | Heavy setup for this simple task |
| **Apps Script trigger** | No code to deploy | Google Workspace only; JS not Python |

For the current workload (4 small files, < 60s processing), GitHub Actions
is the right balance of simplicity, auditability, and zero ops overhead.
Migrate to Airflow only if the pipeline grows to 10+ files or requires
cross-job dependencies.

---

## How to run the SQL queries

**Tool required:** [DB Browser for SQLite](https://sqlitebrowser.org/dl/) — free, no account needed.

**Steps:**
1. Download DB Browser for SQLite and install it
2. Open DB Browser → click **New Database** → save as `3mtt.db`
3. Import each cleaned CSV via **File → Import → Table from CSV file** using these table names:

| CSV file | Table name |
|---|---|
| `fellows_cohort_cleaned.csv` | `fellows_cohort` |
| `alc_weekly_log_cleaned.csv` | `alc_weekly_log` |
| `reflection_survey_cleaned.csv` | `reflection_survey` |
| `employer_engagement_cleaned.csv` | `employer_engagement` |

> ✅ Make sure **"Column names in first line"** is ticked on each import.

4. Click the **Execute SQL** tab → open `3mtt_analysis.sql` → press **F5** to run

**Expected results:**

| Query | Rows returned |
|---|---|
| Q1 — Bottom 10 ALCs by completion rate | 10 rows |
| Q2 — Fellows absent 3+ consecutive weeks | ~200 rows |
| Q3 — Weekly attendance trend by zone | 48 rows |
| Q4 — Certification rate by track and state | ~200 rows |
| Q5 — At-risk fellows CTE | 5 rows |

**SQL dialect:** SQLite
