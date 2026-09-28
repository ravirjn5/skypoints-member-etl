# SkyPoints Member ETL

Take-home assessment for the SkyPoints airline loyalty program, built on Snowflake.

Two feeds come in every day: a pipe-delimited member file and a JSON redemption feed from partner airlines. The pipeline loads both, checks them, splits members into one table per country with "latest record wins", and joins redemptions back to members.

## Approach

- Snowflake SQL and stored procedures only.
- Files go to an internal stage and load with COPY INTO.
- One master procedure runs every step in order, tracked by a load id, and resumes from the failed step on a rerun.
- Every script can be rerun without failing or duplicating data.
- Source files in `data/` are never edited.

Design decisions and scale notes: `docs/DESIGN.md`. Data issues and assumptions: `docs/ANALYSIS.md`.

## How to run

1. In Snowsight, run the scripts in `sql/` in number order: `00` to `20`.
2. Upload the day 1 files from `data/brief_samples/` to the stage `RAW.LANDING`, path `members` for the .txt and `redemptions` for the .json.
3. `CALL SKYPOINTS_DB.CTRL.SP_MASTER_LOAD();`
4. For day 2 and the late file, upload the files from `data/test_scenarios/` and call it again. `sql/manual_checks/run_step7_check.sql` has the full sequence, including a forced failure and restart.
5. Run `sql/99_tests.sql` to see every test result.

## Where each deliverable is

| Deliverable | File |
|---|---|
| DDL for raw, staging and country tables | `sql/00_setup.sql`, `sql/01_tables.sql`, `sql/02_config.sql` |
| Staging load with Age and Stale_Member | `sql/11_sp_load_staging.sql` |
| Country split, latest record wins | `sql/12_sp_validate_publish.sql` |
| Redemption JSON flatten and join to members | `sql/13_sp_redemptions.sql` |
| Data validations | `sql/11_sp_load_staging.sql` (row level), `sql/12_sp_validate_publish.sql` (batch level) |
| Orchestration and restart | `sql/20_sp_master.sql` |
| Tests | `sql/99_tests.sql` |
| Demo | `docs/DEMO.md` |

## Folders

- `data/brief_samples` - the member file and redemption JSON from the brief, saved as files
- `data/test_scenarios` - **test data I created to prove specific cases, not part of the brief.** `data/test_scenarios/README.md` lists what each row proves
- `data/country_extracts` - USA.csv, IND.csv and AUS.xlsx, kept as received. Not loaded (see `docs/ANALYSIS.md`)
- `sql` - scripts in run order; `sql/manual_checks` has the step by step checks I used while building
- `docs` - analysis, design notes, demo script

## Main assumptions

Full list in `docs/ANALYSIS.md`.
- The daily member file has new and changed members; nobody is deleted for being missing.
- Latest record wins by the file's date and time; inside one file, by the later flight date. Real ties go to quarantine.
- A late, older file can't roll a member back.
- Age and Stale_Member are as of the file date. Stale means more than 90 days.
- Member_Id is the key. Only configured countries get tables; unknown countries go to quarantine.
