# Data analysis and assumptions

Notes from going through the brief before building anything. Issues were checked against the actual samples, not just the text.

## 0. Scope and countries

**What is in scope.** The source system does the extraction. It finds the member data and sends two files every day: a member flat file and a redemption JSON feed. My pipeline starts when those files land: load, validate, split by country, flatten the JSON and join it back.

**Countries are fixed, driven by config.** The brief doesn't list the countries, so the starting list comes from the sample data:

| Value in file | Clean code | Table |
|---|---|---|
| USA | USA | TABLE_USA |
| IND | IND | TABLE_INDIA |
| PHIL | PHL | TABLE_PHILIPPINES |
| CAN | CAN | TABLE_CANADA |
| AU | AUS | TABLE_AUSTRALIA |

- These tables are created up front from a country config table. The load never creates a table on its own.
- A mapping table turns messy values into one code, so PHIL and PHL can't end up as two tables.
- An unknown country (say SGP) goes to quarantine as UNMAPPED_COUNTRY. The rest of the batch still publishes.
- Adding a country is a business call. If approved: one config row and one mapping row, rerun the table setup proc (it only creates missing tables), then reprocess the OPEN quarantine rows for that country and mark them REPROCESSED.
- If an existing member comes in with an unknown country, that row is quarantined and the member stays in their current country table until it's sorted.

**Dates.** Raw keeps dates exactly as the source sent them. From staging onwards every date is a DATE column, so they all show the same way: YYYY-MM-DD.

## 1. Member flat file

| # | What I found | Why it matters | How I handle it |
|---|---|---|---|
| 1 | Layout table has 11 columns including Post Code (position 9). Header and detail rows have only 10 fields, no Post Code. | Parsing by the layout table would shift DOB and Is_Active by one column. | Parse by the actual header. Keep POST_CODE as a nullable column since it's in the spec, loaded as NULL for now. |
| 2 | Member Name is marked as the key column, but names are not unique in real life. | Using name as key would merge different people. | Member_Id is the business key. |
| 3 | Country values are not controlled: USA, IND, CAN, but also PHIL and AU. | PHIL and AU would become extra "countries". | Mapping table to one code (PHL, AUS). Unknown country goes to quarantine (see section 0). |
| 4 | DOB is MMDDYYYY, the other dates are YYYYMMDD. | One format for all columns gives wrong or NULL dates. | Date format per column. |
| 5 | Staging sample shows DOB 3051985. The leading zero was lost because it was treated as a number somewhere. | 7 digits doesn't parse as MMDDYYYY. | Raw stays as text. Pad to 8 digits and flag it as a warning. |
| 6 | Staging sample has Agent_Name blank for Ravi, Mateo, Nora and Jacob (4 of 5 rows), but the file has "Sam" for all of them. | Data got lost between file and staging and nothing flagged it. | Batch check comparing raw vs staging, column by column. Blocks the batch if a value goes missing without a reason. |

## 2. Redemption JSON

| # | What I found | How I handle it |
|---|---|---|
| 7 | One document per member, with a nested `redemptions` array. | FLATTEN to one row per transaction. |
| 8 | `member_id` is a string ("223457"), same as the member file. | Keep it as VARCHAR on both sides, never cast to number, so the join is safe. |
| 9 | RX10092 is PENDING, so the same txn_id can come again later with a new status. | txn_id is the key, newer feed_date wins (MERGE). |
| 10 | A redemption can arrive for a member we haven't loaded yet. | LEFT JOIN to members and flag orphans instead of dropping them. |

## 3. Extra files

USA.csv, IND.csv and AUS.xlsx came with the brief but aren't part of the two daily feeds or the deliverables, so they are not loaded.

## 4. Assumptions

| # | Assumption |
|---|---|
| A1 | The daily member file has new and changed members, not a full snapshot. A member missing from a file is never deleted. |
| A2 | "Latest record wins" across files is decided by the file date and time in the file name: the newer file wins. Inside one file, if a member appears twice with different values, the row with the later Last_Flight_Date wins. If the flight dates are equal or empty, both rows go to quarantine and the member keeps their current record. Exact duplicate rows are treated as one. |
| A3 | A record older than what is already published is ignored. A late file can't roll a member back to an old country. |
| A4 | Age and Stale_Member are calculated as of the file date, not today. Rerunning the same file gives the same result. |
| A5 | Member_Id is the business key, not Member_Name. It's kept as text, any length up to 18. |
| A6 | Only the configured countries get tables. Unmapped countries go to quarantine and never create a table. |
| A7 | Bad rows are never dropped silently. They go to a quarantine table with the reason. |
| A8 | The brief gives no file names. Following its file name spec (name string, date and time, extension), I use `members_YYYYMMDD_HHMMSS.txt` and `redemptions_YYYYMMDD.json`. The date and time in the name is what matters for ordering; the extension doesn't. |
| A9 | A member with no flight date is measured for staleness from their enrollment date. |
| A10 | Redemption txn_id is unique across feeds. A later feed can update a transaction's status, and the newest feed_date wins. |
| A11 | Stale means more than 90 days. Exactly 90 days is not stale. |
| A12 | All dates in staging and target tables are DATE type (YYYY-MM-DD). Raw keeps the source text. |

## 5. Open questions (would ask the business if I could)

- Is Post Code expected in the file later, or should it come out of the spec?
- Is the daily member file a delta or a full snapshot? (I assumed delta, A1.)
- Can the source add a record-level last updated timestamp? The file has none, so I order by the file timestamp (A2).
- What are the actual file names and extensions from the source system? (A8)
