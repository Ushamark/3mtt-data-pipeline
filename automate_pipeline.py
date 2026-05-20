#!/usr/bin/env python3
"""
3MTT Data Pipeline — Automation Script
Ingests fellows_cohort.csv, applies cleaning + dedup + standardisation,
emits a structured run-log, and outputs a clean CSV.

Usage:
    python automate_pipeline.py --input /path/to/fellows_cohort.csv [--output /path/to/output.csv]

Idempotent: running twice on the same input produces identical output.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

import pandas as pd


# ─── HELPERS ─────────────────────────────────────────────────────────────────

def log(run_log: dict, key: str, value):
    run_log[key] = value


def standardise_phone(phone_str: str) -> str:
    """Normalise any Nigerian phone variant to 234XXXXXXXXXX."""
    p = re.sub(r'[\s\-]', '', str(phone_str).strip())
    if re.match(r'^234[0-9]{10}$', p):
        return p
    if re.match(r'^\+234[0-9]{10}$', p):
        return p[1:]
    if re.match(r'^00(234)[0-9]{10}$', p):
        return p[2:]
    if re.match(r'^00[789][0-9]{9}$', p):
        return '234' + p[3:]
    if re.match(r'^0[789][0-9]{9}$', p):
        return '234' + p[1:]
    if re.match(r'^[789][0-9]{9}$', p):
        return '234' + p
    return ''


def file_md5(path: str) -> str:
    """Return MD5 of file — used to guarantee idempotency proof."""
    h = hashlib.md5()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


# ─── PIPELINE ────────────────────────────────────────────────────────────────

def run_pipeline(input_path: str, output_path: str) -> dict:
    run_log = {
        "pipeline": "3MTT Fellows Cohort Cleaner v1.0",
        "run_timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "input_path": input_path,
        "output_path": output_path,
        "input_md5": None,
        "rows_in": None,
        "rows_out": None,
        "issues_found": [],
        "processing_time_seconds": None,
        "status": "running",
    }

    t0 = time.perf_counter()

    # ── 1. Validate input path ────────────────────────────────────────────
    if not os.path.exists(input_path):
        run_log["status"] = "ERROR"
        run_log["error"] = f"Input file not found: {input_path}"
        _print_log(run_log)
        sys.exit(1)

    run_log["input_md5"] = file_md5(input_path)

    # ── 2. Load ───────────────────────────────────────────────────────────
    try:
        df = pd.read_csv(input_path)
    except Exception as exc:
        run_log["status"] = "ERROR"
        run_log["error"] = f"Failed to parse CSV: {exc}"
        _print_log(run_log)
        sys.exit(1)

    run_log["rows_in"] = len(df)

    required_cols = {
        'fellow_id', 'state', 'alc_code',
        'completion_status', 'certification_status',
        'enrollment_date', 'track', 'cohort_number'
    }
    missing_cols = required_cols - set(df.columns)
    if missing_cols:
        run_log["status"] = "ERROR"
        run_log["error"] = f"Missing required columns: {missing_cols}"
        _print_log(run_log)
        sys.exit(1)

    # ── 3. Validate a deliberately bad row (graceful error handling) ───────
    # Any row where fellow_id is null or does not match expected pattern
    bad_rows = df[df['fellow_id'].isnull() | ~df['fellow_id'].astype(str).str.match(r'^3MTT-F\d{5}$')]
    if not bad_rows.empty:
        msg = (
            f"{len(bad_rows)} row(s) have malformed or missing fellow_id "
            f"(expected '3MTT-FXXXXX'). Row indices: {list(bad_rows.index[:5])}. "
            "These rows will be quarantined."
        )
        run_log["issues_found"].append({"issue": "malformed_fellow_id", "count": len(bad_rows), "detail": msg})
        print(f"[WARN] {msg}", file=sys.stderr)
        df = df[~df.index.isin(bad_rows.index)].copy()

    # ── 4. Exact duplicate rows ────────────────────────────────────────────
    exact_dups = df.duplicated().sum()
    if exact_dups:
        run_log["issues_found"].append({"issue": "exact_duplicate_rows", "count": int(exact_dups)})
    df = df.drop_duplicates()

    # ── 5. Duplicate fellow_id (non-identical rows) ────────────────────────
    id_dups = df.duplicated('fellow_id').sum()
    if id_dups:
        run_log["issues_found"].append({"issue": "duplicate_fellow_id", "count": int(id_dups)})
    df = df.drop_duplicates(subset='fellow_id', keep='first')

    # ── 6. State normalisation ─────────────────────────────────────────────
    before_states = df['state'].nunique()
    df['state'] = df['state'].str.strip().str.title()
    after_states = df['state'].nunique()
    if before_states != after_states:
        run_log["issues_found"].append({
            "issue": "mixed_case_states",
            "before_unique": int(before_states),
            "after_unique": int(after_states),
        })

    # ── 7. Missing ALC codes ───────────────────────────────────────────────
    missing_alc = df['alc_code'].isnull().sum()
    if missing_alc:
        run_log["issues_found"].append({"issue": "missing_alc_code", "count": int(missing_alc)})

    # ── 8. enrollment_date parse / out-of-range ────────────────────────────
    df['enrollment_date'] = pd.to_datetime(df['enrollment_date'], errors='coerce')
    unparseable = df['enrollment_date'].isnull().sum()
    if unparseable:
        run_log["issues_found"].append({"issue": "unparseable_enrollment_date", "count": int(unparseable)})

    # ── 9. Phone standardisation (if column present) ──────────────────────
    if 'phone_number' in df.columns:
        df['phone_number'] = df['phone_number'].apply(standardise_phone)
        blanks = (df['phone_number'] == '').sum()
        if blanks:
            run_log["issues_found"].append({"issue": "unrecognisable_phone", "count": int(blanks)})

    # ── 10. Write output ───────────────────────────────────────────────────
    os.makedirs(os.path.dirname(output_path) if os.path.dirname(output_path) else '.', exist_ok=True)
    df['enrollment_date'] = df['enrollment_date'].dt.strftime('%Y-%m-%d')
    df.to_csv(output_path, index=False)

    # ── 11. Finalise log ───────────────────────────────────────────────────
    run_log["rows_out"] = len(df)
    run_log["rows_dropped"] = run_log["rows_in"] - len(df)
    run_log["processing_time_seconds"] = round(time.perf_counter() - t0, 4)
    run_log["status"] = "SUCCESS"
    run_log["output_md5"] = file_md5(output_path)

    return run_log


def _print_log(run_log: dict):
    print(json.dumps(run_log, indent=2, default=str))


# ─── ENTRY POINT ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="3MTT Fellows Cohort cleaning pipeline. Idempotent. Emits JSON run-log to stdout."
    )
    parser.add_argument('--input',  required=True, help='Path to input fellows_cohort.csv')
    parser.add_argument('--output', default='outputs/fellows_clean.csv',
                        help='Path for cleaned output CSV (default: outputs/fellows_clean.csv)')
    args = parser.parse_args()

    run_log = run_pipeline(args.input, args.output)
    _print_log(run_log)

    if run_log["status"] != "SUCCESS":
        sys.exit(1)


if __name__ == '__main__':
    main()
