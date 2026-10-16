# WRDS complete-NBBO spread pipeline

This pipeline reads one ETF-date-anchor observation per input row, queries the corresponding WRDS Daily TAQ `complete_nbbo_YYYYMMDD` table, and writes time-weighted relative quoted spreads for six event-time windows.

## Files

- `run_wrds_spreads.R`: test and batch program.
- `input_example.csv`: required input layout and the first XLK test case.
- `run_output/spreads.csv`: one row per input row and window.
- `run_output/diagnostics.csv`: coverage, invalid-price, locked/crossed-duration, and error diagnostics.

## Method

For each quote state, the relative quoted spread in basis points is:

`10,000 * (ask - bid) / ((ask + bid) / 2)`

The program weights each state by the number of seconds for which it is active inside each window. It retrieves the final quote at or before the first window boundary so a previously active quote carries into the window. Locked quotes (`bid = ask`) are retained with a zero spread. Crossed quotes (`bid > ask`) are excluded for exactly the time they remain active; the prior quote is not carried forward across that interval. Missing and non-positive prices are also excluded and reported separately.

The six windows are `[-30,-10)`, `[-10,0)`, `[0,5)`, `[5,10)`, `[10,15)`, and `[15,20)` minutes relative to `anchor_time`.

## One-time setup

Use R 4.2 or later. Install the packages once:

```r
install.packages(c("data.table", "DBI", "RPostgres"))
```

Add WRDS credentials to `~/.Renviron` locally. Do not put credentials in the input CSV, script, shared folder, or Git repository.

```text
WRDS_USER=your_wrds_username
WRDS_PASSWORD=your_wrds_password
```

Restart R after editing `~/.Renviron`. Your WRDS account must have access to Daily TAQ.

## Input CSV

Required columns:

| Column | Meaning |
| --- | --- |
| `ticker` | ETF root ticker, for example `XLK` |
| `date` | Quote date in `YYYY-MM-DD` format |
| `anchor_time` | Event-time anchor in Eastern Time, `HH:MM:SS` |
| `day_type` | `event` or `comparison` |
| `matched_event_date` | Event date that supplies the anchor time |

For comparison days, copy the actual announcement time from the matched event into `anchor_time`.

## Run the checks

From the pipeline directory:

```bash
Rscript run_wrds_spreads.R --self-test
```

The self-test verifies the time-weighting boundaries, carry-in quote, locked-quote inclusion, and crossed-quote exclusion without accessing WRDS.

## First live test

```bash
Rscript run_wrds_spreads.R \
  --input input_example.csv \
  --output-dir run_output/test_xlk_20190130 \
  --test-xlk
```

This queries `taqm_2019.complete_nbbo_20190130` for XLK around 14:00 ET and creates `spreads.csv` and `diagnostics.csv` in `run_output/test_xlk_20190130/`.

## Full batch

Replace `input_example.csv` with the full input file and omit `--test-xlk`:

```bash
Rscript run_wrds_spreads.R \
  --input full_input.csv \
  --output-dir run_output/full_batch
```

Each input row is handled independently. A failed date is retained in both output files with a blank spread and a message in `processing_error`; later rows continue processing.

## Output interpretation

`spreads.csv` contains the requested research measure. `diagnostics.csv` reports the duration used or excluded in every window. `valid_coverage_pct` is the share of window seconds with a valid or locked two-sided quote. A result with limited coverage should be reviewed before regression analysis.

## Sources

- WRDS Millisecond Intraday Indicators: <https://wrds-www.wharton.upenn.edu/pages/get-data/nyse-trade-and-quote/millisecond-trade-and-quote-daily-product-2003-present-updated-daily/taq-millisecond-tools/millisecond-intraday-indicators-by-wrds/>
- NYSE Daily TAQ Client Specification: <https://wrds-www.wharton.upenn.edu/documents/1967/Daily_TAQ_Client_Spec_v4.0.pdf>
