# Demo script

About 15 minutes. Start from a clean database.

## 1. Setup (1 min)

Run in order: `00_setup`, `01_tables`, `02_config`, `10`, `11`, `12`, `13`, `20`.
Show the schemas (RAW, STG, MAIN, CTRL, DQ) and the five empty country tables.

## 2. Day 1: the brief's sample (3 min)

Upload `data/brief_samples/members_20240115_010000.txt` (path members) and `redemptions_20240115.json` (path redemptions).

```sql
CALL CTRL.SP_MASTER_LOAD();
```

Show:
- `CTRL.PROCESS_EXEC_LOG`: six steps, each with counts.
- `STG.MEMBER`: PHIL became PHL, AU became AUS, DOB 1985-03-05, Elena's age 38, everyone stale.
- One member in each country table.
- `MAIN.V_REDEMPTION_ENRICHED`: two transactions for Elena.

Talk about: raw as text, per column date formats, age as of the file date.

## 3. Day 2: the test scenarios (5 min)

Upload `data/test_scenarios/members_20240116_010000.txt` and `redemptions_20240116.json`. Walk through `data/test_scenarios/README.md` first.

```sql
CALL CTRL.SP_MASTER_LOAD();
```

Show:
- Ravi is only in TABLE_USA now, and `MAIN.MEMBER_COUNTRY_MOVE` has IND to USA.
- Elena is PLT (the later flight won inside the same file).
- Nora's LAST_UPDATE_DATE didn't change: nothing changed, nothing rewritten.
- `DQ.MEMBER_QUARANTINE`: Priya (no id), Omar (XYZ), Zara (month 13), Liam twice (conflict).
- `CTRL.PROCESS_ERROR_LOG`: the two warnings.
- RX10092 is now COMPLETED, RX10094 is an orphan, the bad JSON document is in quarantine.

## 4. Late file and restart (3 min)

Upload `data/test_scenarios/members_20240114_230000.txt`. Break a setting:

```sql
UPDATE CTRL.KEY_VALUE_CONFIG SET KEY_VALUE = 'abc' WHERE COLUMN_NAME = 'STALE_DAYS';
CALL CTRL.SP_MASTER_LOAD();   -- fails
```

Show the load as E and the error in the error log. Fix it and run again:

```sql
UPDATE CTRL.KEY_VALUE_CONFIG SET KEY_VALUE = '90' WHERE COLUMN_NAME = 'STALE_DAYS';
CALL CTRL.SP_MASTER_LOAD();   -- resumes at staging
```

Show: the same load resumed at the staging step, the raw steps didn't run again, and publish did nothing because the file is older. Ravi is still in the USA.

## 5. Tests (1 min)

Run `99_tests.sql` and show the summary: all passed.

## Questions I expect

- Why not one table with a country column? (Security notes in DESIGN.md.)
- What changes at billions of rows? (Scale section in DESIGN.md.)
- Why is the key Member_Id? Why a LEFT JOIN for redemptions?
