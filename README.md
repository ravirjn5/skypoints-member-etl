# SkyPoints Member ETL

Take-home assessment for the SkyPoints airline loyalty program, built on Snowflake.

Two feeds come in every day: a pipe-delimited member file and a JSON redemption feed from partner airlines. The pipeline loads both into Snowflake, runs data quality checks, and splits members into one table per country. If a member moves country, the latest record wins.

Still in progress. I am building it in small steps, one commit per step.

## Approach

- Snowflake SQL and stored procedures only (Snowflake Scripting).
- Files are uploaded to an internal stage and loaded with COPY INTO.
- One master procedure runs every step in order, tracked by a load id, and resumes from the failed step on a rerun. It follows the same pattern as an orchestration framework I built on a previous project.
- Every script can be rerun without failing or duplicating data.
- Source files in `data/` are never edited.

## Folders

- `data/brief_samples` - the sample member file and redemption JSON from the brief
- `data/country_extracts` - USA.csv, IND.csv and AUS.xlsx, kept as received. Reference only, not loaded (see `docs/ANALYSIS.md`)
- `data/test_scenarios` - test data I created to prove specific cases. Not part of the brief.
- `sql` - scripts, run in number order
- `docs` - data analysis, design notes and demo script

## How to run

To be added.

## Where each deliverable is

| Deliverable | File |
|---|---|
| DDL for raw, staging and country tables | `sql/00` to `sql/05` |
| Staging load with Age and Stale_Member | `sql/11_sp_load_staging.sql` |
| Country split, latest record wins | `sql/13_sp_publish_country.sql` |
| Redemption JSON flatten and join to members | `sql/14_sp_redemptions.sql` |
| Data validations | `sql/11`, `sql/12`, `sql/99_tests.sql` |
| Demo | `docs/DEMO.md` |

## Assumptions

To be added after the data analysis step (`docs/ANALYSIS.md`).
