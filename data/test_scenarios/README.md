# Test scenarios (created test data, not from the brief)

Load order for the demo: brief samples (day 1), then these day 2 files, then the late file.

## members_20240116_010000.txt (day 2)

| Row | Member | What it proves |
|---|---|---|
| 1 | Ravi 223458, now USA | Country move IND to USA. Recent flight, so not stale |
| 2-3 | Elena 223457 twice, GLD (flight 2012) and PLT (flight 2024) | Same member twice in one file: later flight date wins, Elena becomes PLT |
| 4 | Nora 22345, identical to day 1 | Nothing changed, row is not rewritten |
| 5-6 | Liam 223470 twice, same flight date, different tier | Can't tell which is newer: both go to quarantine |
| 7 | Omar, country XYZ | Unknown country: quarantine |
| 8 | Priya, empty Member_Id | Missing mandatory field: quarantine |
| 9 | Zara, enrollment date 20211313 | Impossible date on a mandatory field: quarantine |
| 10 | Aiko, DOB 3051985 | Leading zero lost: fixed to 1985-03-05 with a warning |
| 11 | Lucas, tier DIA, DOB text NULL | Unknown tier warning, NULL text treated as empty |

## members_20240114_230000.txt (late file)

Ravi back in IND, but the file time is older than day 2. Loaded after day 2 to prove a late file can't roll a member back. Ravi must stay in USA.

## redemptions_20240116.json (day 2)

| Document | What it proves |
|---|---|
| 223457: RX10092 now COMPLETED | Status update on an existing transaction |
| 223457: RX10093 with -300 miles | Non-positive miles flagged |
| 999999: RX10094 | Member doesn't exist: kept and shown as orphan |
| 223458: redemptions is a string | Bad document: quarantined |
