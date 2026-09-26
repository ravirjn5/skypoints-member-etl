/* 00_setup.sql
   Database, schemas, file formats and the landing stage.
   Safe to rerun. Runs with your current role (ACCOUNTADMIN on a trial is fine). */

USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS SKYPOINTS_DB;
USE DATABASE SKYPOINTS_DB;

CREATE SCHEMA IF NOT EXISTS RAW;    -- files exactly as received, all text
CREATE SCHEMA IF NOT EXISTS STG;    -- typed columns, Age, Stale_Member, row level checks
CREATE SCHEMA IF NOT EXISTS MAIN;   -- final data: country tables, current members, move history, redemptions
CREATE SCHEMA IF NOT EXISTS CTRL;   -- config, load control, orchestration
CREATE SCHEMA IF NOT EXISTS DQ;     -- quarantine and check results

-- Member file: pipe delimited, header skipped.
-- Every line starts with |, so field 1 is always empty and field 2 is the record type.
CREATE OR REPLACE FILE FORMAT RAW.FF_MEMBER_PIPE
    TYPE = CSV
    FIELD_DELIMITER = '|'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = NONE
    ESCAPE_UNENCLOSED_FIELD = NONE      -- default is backslash, which would change the data
    TRIM_SPACE = FALSE
    EMPTY_FIELD_AS_NULL = FALSE         -- raw keeps an empty value as '' exactly as sent
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- Redemption feed: works for one JSON document per file or one per line.
CREATE OR REPLACE FILE FORMAT RAW.FF_REDEMPTION_JSON
    TYPE = JSON
    STRIP_OUTER_ARRAY = TRUE;

-- Internal stage. Upload with PUT or Snowsight into:
--   @RAW.LANDING/members/       members_YYYYMMDD_HHMMSS.txt
--   @RAW.LANDING/redemptions/   redemptions_YYYYMMDD.json
-- IF NOT EXISTS (not OR REPLACE) so a rerun never wipes uploaded files.
CREATE STAGE IF NOT EXISTS RAW.LANDING
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing area for the daily member and redemption files';

SHOW SCHEMAS IN DATABASE SKYPOINTS_DB;
