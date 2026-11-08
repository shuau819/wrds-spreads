# WRDS complete-NBBO liquidity pipeline

This repository contains an R Markdown notebook for calculating time-weighted
relative quoted spreads from WRDS Daily TAQ `complete_nbbo` tables. It is
designed for an FOMC event study using event days and matched comparison days.

The main file is **`wrds_spread_pipeline.Rmd`**. It includes the methodology,
explanations, reusable R functions, an offline self-test, an XLK live test, and
the full batch workflow.

## What the notebook calculates

For each ETF-date-anchor row, the notebook calculates:

- 50 one-minute spreads from 30 minutes before to 20 minutes after the anchor;
- seven research windows: `[-30,-10)`, `[-10,0)`, `[0,1)`, `[1,5)`,
  `[5,10)`, `[10,15)`, and `[15,20)` minutes;
- a main version that keeps locked quotes (`bid = ask`); and
- a robustness version that excludes locked quotes;
- one-cent spread percentages; and
- time-weighted displayed bid and ask depth with side-specific coverage.

The relative quoted spread is measured in basis points:

```text
10,000 * (ask - bid) / ((ask + bid) / 2)
```

Each quote is weighted by the number of seconds for which it is active. A quote
already active when a window begins is included. Crossed quotes (`bid > ask`)
are excluded for their exact active duration without filling the interval with
the previous quote. Missing, nonfinite, zero, negative, and ambiguous prices are
excluded and reported in the diagnostics. `time_m` and `time_m_nano` are both
used, so distinct nanosecond updates are not merged.

Research-window spreads are weighted by usable seconds. A spread enters the
main regression output when usable quotes cover at least 99% of the window. A
99.9% flag is retained for sensitivity analysis. Spreads above 100 basis points
are flagged for review rather than automatically removed.

## Repository files

- `wrds_spread_pipeline.Rmd`: current documented analysis workflow.
- `input_example.csv`: one-row XLK test input for January 30, 2019 at 14:00 ET.
- `pilot_input/test_input_33_rows.csv`: 11-ETF × 3-date pilot input.
- `pilot_input/pilot_input_33_rows.xlsx`: Excel copy of the same pilot input.
- `run_wrds_spreads.R`: earlier command-line version retained only for legacy
  reference; use the RMD for the current methodology.
- `run_output/`: locally generated output folder; it is not uploaded to GitHub.

## 1. Download the repository

Use the green **Code** button on GitHub to download a ZIP, or clone it:

```bash
git clone https://github.com/shuau819/wrds-spreads.git
cd wrds-spreads
```

Open `wrds_spread_pipeline.Rmd` in RStudio.

## 2. Install the required R packages

Run this once in the R console:

```r
install.packages(c("data.table", "DBI", "RPostgres", "rmarkdown", "knitr", "usethis"))
```

R 4.2 or later is recommended. The WRDS account must have access to NYSE Daily
TAQ.

## 3. Store WRDS credentials locally

Never type a username or password into the RMD, a CSV, or a GitHub file. In the
R console, run:

```r
usethis::edit_r_environ()
```

Add these lines using your own credentials:

```text
WRDS_USER=your_wrds_username
WRDS_PASSWORD=your_wrds_password
```

Save the file and restart RStudio. `.Renviron` is excluded by `.gitignore`.

## 4. Prepare the input CSV

The CSV must have one row per ETF and date and exactly these required columns:

| Column | Meaning |
| --- | --- |
| `ticker` | ETF root ticker, for example `XLK` |
| `date` | Quote date in `YYYY-MM-DD` format |
| `anchor_time` | Event-time anchor in Eastern Time, `HH:MM:SS` |
| `day_type` | `event` or `comparison` |
| `matched_event_date` | Event date associated with the row |

Example:

```csv
ticker,date,anchor_time,day_type,matched_event_date
XLK,2019-01-30,14:00:00,event,2019-01-30
XLK,2019-01-23,14:00:00,comparison,2019-01-30
XLK,2019-02-06,14:00:00,comparison,2019-01-30
```

For a comparison day, use the actual FOMC announcement time from its matched
event day. For example, if the event announcement was at 14:00, the comparison
day also uses `14:00:00`.

## 5. Run the notebook in RStudio

Run the chunks from top to bottom. The safest workflow is:

1. Run Sections 1-13. When `file.choose()` appears, select the input CSV.
2. Confirm that the offline self-test in Section 13 ends with
   `Offline self-tests passed.` This test does not access WRDS.
3. For the first live check, click the green arrow on the code chunk in
   Section 14. It queries only XLK on January 30, 2019 at 14:00.
4. After the live test works, click the green arrow on the batch chunk in
   Section 15 and select the complete input CSV.
5. Click the green arrow on the output chunk in Section 16 to write the CSVs.

The live-test, batch, and output chunks have `eval=FALSE`. This is intentional:
pressing **Knit** will show the report without automatically launching a large
WRDS query. Run these three chunks manually when data should be downloaded.

Before running Section 16, change this line if a different output folder is
preferred:

```r
output_dir <- "run_output/full_batch"
```

## 6. Output files

The selected output folder will contain:

- `minute_spreads.csv`: one row per ETF × date × minute × locked treatment;
- `spreads.csv`: one row per ETF × date × research window × locked treatment;
- `diagnostics.csv`: minute- and window-level coverage, excluded seconds by
  reason, locked/crossed/ambiguous duration, displayed-depth coverage,
  large-spread flags, and processing errors.

`locked_treatment = keep_locked` is the main specification.
`locked_treatment = exclude_locked` is the robustness specification.

In `spreads.csv`, `window_spread_bps` is weighted by spread-usable seconds.
`regression_spread_bps` is populated when `coverage_pct >= 99` and at least one
usable second exists. `passes_strict_coverage` records the 99.9% sensitivity
rule. `mean_of_minute_spreads_bps` is retained only for comparison with the
earlier unweighted-minute method.

`one_cent_pct` is the percentage of spread-usable seconds with a dollar spread
within `1e-7` of $0.01. Displayed depth uses `best_bidsizeshares` and
`best_asksizeshares`, which are already measured in shares. Bid and ask depth
coverage are reported separately.

## 7. Basic checks before regression

Check `diagnostics.csv` for:

- non-empty `processing_error` values;
- `passes_coverage = FALSE` and `passes_strict_coverage = FALSE`;
- positive `missing_quote_seconds`, `invalid_price_seconds`, or
  `crossed_seconds`;
- positive `ambiguous_price_seconds`, `bid_depth_ambiguous_seconds`, or
  `ask_depth_ambiguous_seconds`;
- positive `large_spread_seconds`; and
- unusually low `bid_depth_coverage_pct` or `ask_depth_coverage_pct`.

A small crossed interval no longer automatically removes a window. The main
rule keeps windows with at least 99% spread coverage, while the 99.9% flag makes
the stricter sample reproducible.

## Data source

- [WRDS Millisecond Intraday Indicators](https://wrds-www.wharton.upenn.edu/pages/get-data/nyse-trade-and-quote/millisecond-trade-and-quote-daily-product-2003-present-updated-daily/taq-millisecond-tools/millisecond-intraday-indicators-by-wrds/)
- [NYSE Daily TAQ Client Specification](https://www.nyse.com/publicdocs/nyse/data/Daily_TAQ_Client_Spec_v4.1b.pdf)
