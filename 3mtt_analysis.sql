-- =============================================================
-- 3MTT Data Analyst Stage 2 — SQL Analysis
-- Dialect: SQLite
-- Author: [Your Name]
-- Date: 2026-05-18
-- =============================================================
-- SCHEMA NOTES
-- fellows_cohort    : fellow_id, first_name, last_name, state, alc_code,
--                     cohort_number, track, enrollment_date,
--                     completion_status, certification_status
-- alc_weekly_log    : alc_code, week_number, state, geopolitical_zone,
--                     fellows_present, sessions_held, facilitator_name,
--                     data_quality_flag
-- reflection_survey : fellow_id, week, response_timestamp, survey_score,
--                     phone_number, email
-- employer_engagement: employer_name, sector, state, geopolitical_zone,
--                      engagement_type, engagement_date, alc_code,
--                      fellows_referred
-- =============================================================
-- DATA QUALITY NOTES APPLIED IN QUERIES
--   1. fellows_cohort: 25 duplicate fellow_ids (20 full-row dupes, 5 partial).
--      Deduplicated via CTE using ROW_NUMBER().
--   2. fellows_cohort: 47 rows with NULL alc_code — excluded from ALC queries.
--   3. fellows_cohort: mixed-case state names normalised via UPPER().
--   4. alc_weekly_log: 20 rows with NULL alc_code — excluded from ALC queries.
--   5. alc_weekly_log: 5 rows with week_number = 99 (out-of-range) — excluded.
--   6. reflection_survey: 30 exact duplicate rows — deduplicated via CTE.
--   7. reflection_survey: loaded with skiprows=1 to skip merged Excel title row.
-- =============================================================


-- =============================================================
-- QUESTION 1
-- Which 10 ALCs have the lowest completion rate in the most
-- recent cohort? Show completion rate, total enrolled, and
-- geopolitical zone.
-- Most recent cohort = cohort_number 4 (confirmed from data).
-- =============================================================

WITH deduped_fellows AS (
    -- Remove exact duplicate rows; keep one row per fellow_id
    -- where duplicates exist, keep the first occurrence.
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY fellow_id
                   ORDER BY enrollment_date
               ) AS rn
        FROM fellows_cohort
    )
    WHERE rn = 1
),

cohort4 AS (
    SELECT
        fc.alc_code,
        COUNT(*)                                                  AS total_enrolled,
        SUM(CASE WHEN fc.completion_status = 'complete' THEN 1 ELSE 0 END)
                                                                  AS total_completed,
        ROUND(
            100.0 * SUM(CASE WHEN fc.completion_status = 'complete' THEN 1 ELSE 0 END)
            / COUNT(*), 2
        )                                                         AS completion_rate_pct
    FROM deduped_fellows fc
    WHERE fc.cohort_number = 4          -- most recent cohort
      AND fc.alc_code IS NOT NULL       -- exclude unassigned fellows
    GROUP BY fc.alc_code
    HAVING COUNT(*) >= 3                -- at least 3 fellows for statistical reliability
),

-- Bring in geopolitical zone from alc_weekly_log
-- (fellows_cohort has no zone column; alc_weekly_log does)
alc_zones AS (
    SELECT alc_code,
           geopolitical_zone,
           ROW_NUMBER() OVER (PARTITION BY alc_code ORDER BY week_number) AS rn
    FROM alc_weekly_log
    WHERE alc_code IS NOT NULL
      AND week_number != 99             -- exclude erroneous week
),

alc_zone_single AS (
    SELECT alc_code, geopolitical_zone
    FROM alc_zones
    WHERE rn = 1
)

SELECT
    c4.alc_code,
    az.geopolitical_zone,
    c4.total_enrolled,
    c4.total_completed,
    c4.completion_rate_pct
FROM cohort4 c4
LEFT JOIN alc_zone_single az ON c4.alc_code = az.alc_code
ORDER BY c4.completion_rate_pct ASC
LIMIT 10;


-- =============================================================
-- QUESTION 2
-- Which fellows have been absent (no reflection survey response)
-- for 3 or more consecutive weeks?
-- Return: Fellow ID, ALC code, track, last recorded week.
-- =============================================================

WITH deduped_fellows AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY fellow_id ORDER BY enrollment_date
               ) AS rn
        FROM fellows_cohort
    )
    WHERE rn = 1
),

deduped_survey AS (
    -- Remove duplicate survey responses
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY fellow_id, week ORDER BY response_timestamp
               ) AS rn
        FROM reflection_survey
    )
    WHERE rn = 1
),

-- For each fellow, find the last week they responded
-- and the max week in the dataset (12)
fellow_last_response AS (
    SELECT
        fellow_id,
        MAX(week) AS last_response_week
    FROM deduped_survey
    GROUP BY fellow_id
),

-- The most recent week recorded in the survey dataset
max_week AS (
    SELECT MAX(week) AS max_week FROM deduped_survey
),

-- Fellows whose last response was 3+ weeks before the latest week
absent_fellows AS (
    SELECT
        flr.fellow_id,
        flr.last_response_week,
        mw.max_week,
        (mw.max_week - flr.last_response_week) AS weeks_absent
    FROM fellow_last_response flr
    CROSS JOIN max_week mw
    WHERE (mw.max_week - flr.last_response_week) >= 3

    UNION ALL

    -- Also catch fellows who NEVER responded at all
    SELECT
        df.fellow_id,
        NULL                AS last_response_week,
        mw.max_week,
        mw.max_week         AS weeks_absent
    FROM deduped_fellows df
    CROSS JOIN max_week mw
    WHERE df.fellow_id NOT IN (SELECT DISTINCT fellow_id FROM deduped_survey)
)

SELECT
    af.fellow_id,
    df.alc_code,
    df.track,
    af.last_response_week   AS last_recorded_week,
    af.weeks_absent
FROM absent_fellows af
JOIN deduped_fellows df ON af.fellow_id = df.fellow_id
ORDER BY af.weeks_absent DESC, af.fellow_id;


-- =============================================================
-- QUESTION 3
-- What is the trend in weekly session attendance
-- (sessions_held vs fellows_present) per zone over the last
-- 8 weeks?
-- Last 8 weeks = weeks 5–12 (max valid week is 12).
-- =============================================================

WITH clean_log AS (
    -- Exclude bad week values and null alc_codes
    SELECT *
    FROM alc_weekly_log
    WHERE week_number != 99
      AND alc_code IS NOT NULL
),

last_8_weeks AS (
    SELECT
        geopolitical_zone,
        week_number,
        SUM(sessions_held)    AS total_sessions,
        SUM(fellows_present)  AS total_fellows_present,
        COUNT(alc_code)       AS alcs_reporting
    FROM clean_log
    WHERE week_number >= (SELECT MAX(week_number) - 7 FROM clean_log)
    GROUP BY geopolitical_zone, week_number
)

SELECT
    geopolitical_zone,
    week_number,
    total_sessions,
    total_fellows_present,
    alcs_reporting,
    ROUND(1.0 * total_fellows_present / NULLIF(total_sessions, 0), 2)
        AS avg_fellows_per_session
FROM last_8_weeks
ORDER BY geopolitical_zone, week_number;


-- =============================================================
-- QUESTION 4
-- Which tracks have the highest certification rate, broken
-- down by state? Rank them.
-- =============================================================

WITH deduped_fellows AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY fellow_id ORDER BY enrollment_date
               ) AS rn
        FROM fellows_cohort
    )
    WHERE rn = 1
),

track_state_cert AS (
    SELECT
        -- Normalise mixed-case state names
        UPPER(TRIM(state))      AS state_clean,
        track,
        COUNT(*)                AS total_enrolled,
        SUM(CASE WHEN certification_status = 'certified' THEN 1 ELSE 0 END)
                                AS total_certified,
        ROUND(
            100.0 * SUM(CASE WHEN certification_status = 'certified' THEN 1 ELSE 0 END)
            / COUNT(*), 2
        )                       AS certification_rate_pct
    FROM deduped_fellows
    GROUP BY UPPER(TRIM(state)), track
    HAVING COUNT(*) >= 2       -- minimum sample for meaningful rate
)

SELECT
    state_clean     AS state,
    track,
    total_enrolled,
    total_certified,
    certification_rate_pct,
    RANK() OVER (
        PARTITION BY state_clean
        ORDER BY certification_rate_pct DESC
    )               AS rank_within_state,
    RANK() OVER (
        ORDER BY certification_rate_pct DESC
    )               AS overall_rank
FROM track_state_cert
ORDER BY certification_rate_pct DESC, state_clean, track;


-- =============================================================
-- QUESTION 5 — AT-RISK FELLOWS CTE
-- Flag 'at-risk' fellows:
--   (a) completion_status = 'incomplete'  AND
--   (b) no survey response in the last 2 weeks  AND
--   (c) enrollment_date more than 10 weeks ago
-- "Last 2 weeks" = survey weeks 11 and 12 (max week = 12).
-- "10 weeks ago" = enrollment_date < 70 days before latest
--   survey response timestamp (approx. using 2024-04-28).
-- =============================================================

WITH deduped_fellows AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY fellow_id ORDER BY enrollment_date
               ) AS rn
        FROM fellows_cohort
    )
    WHERE rn = 1
),

deduped_survey AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY fellow_id, week ORDER BY response_timestamp
               ) AS rn
        FROM reflection_survey
    )
    WHERE rn = 1
),

-- Fellows who responded in the last 2 weeks (weeks 11–12)
recent_responders AS (
    SELECT DISTINCT fellow_id
    FROM deduped_survey
    WHERE week >= 11     -- last 2 weeks of the 12-week survey window
),

-- Fellows enrolled more than 10 weeks before latest survey date
-- Latest survey response: 2024-04-28  → 10 weeks back = 2024-02-18
enrolled_early AS (
    SELECT fellow_id
    FROM deduped_fellows
    WHERE DATE(enrollment_date) < DATE('2024-04-28', '-70 days')
),

at_risk_fellows AS (
    SELECT
        df.fellow_id,
        df.alc_code,
        df.state,
        df.track,
        df.cohort_number,
        df.enrollment_date,
        df.completion_status,
        df.certification_status,
        CASE
            WHEN df.fellow_id NOT IN (SELECT fellow_id FROM deduped_survey)
            THEN NULL
            ELSE (
                SELECT MAX(week)
                FROM deduped_survey ds
                WHERE ds.fellow_id = df.fellow_id
            )
        END                         AS last_survey_week,
        CASE
            WHEN df.fellow_id NOT IN (SELECT fellow_id FROM deduped_survey)
            THEN NULL
            ELSE (
                SELECT ROUND(AVG(survey_score), 2)
                FROM deduped_survey ds
                WHERE ds.fellow_id = df.fellow_id
            )
        END                         AS avg_survey_score,
        'AT-RISK'                   AS risk_flag
    FROM deduped_fellows df
    JOIN enrolled_early ee ON df.fellow_id = ee.fellow_id
    WHERE df.completion_status = 'incomplete'
      AND df.fellow_id NOT IN (SELECT fellow_id FROM recent_responders)
)

SELECT
    fellow_id,
    alc_code,
    state,
    track,
    cohort_number,
    enrollment_date,
    last_survey_week,
    avg_survey_score,
    risk_flag
FROM at_risk_fellows
ORDER BY avg_survey_score ASC, fellow_id;

-- End of file
-- Total queries: 5
-- Dialect: SQLite
-- Note: To run in DuckDB or PostgreSQL, replace UPPER(TRIM(state))
--       with INITCAP(TRIM(state)) for proper title-case normalisation.
--       The DATE() and DATE arithmetic syntax is SQLite-specific.
