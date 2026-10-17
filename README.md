# WRDS complete-NBBO spread pipeline

This repository contains an R Markdown notebook for calculating time-weighted
relative quoted spreads from WRDS Daily TAQ `complete_nbbo` tables. It is
designed for an FOMC event study using event days and matched comparison days.

The main file is **`wrds_spread_pipeline.Rmd`**. It includes the methodology,
explanations, reusable R functions, an offline self-test, an XLK live test, and
the full batch workflow.

## What the notebook calculates

For each ETF-date-anchor row, the notebook calculates:

- 50 one-minute spreads from 30 minutes before to 20 minutes after the anchor;
- six research windows: `[-30,-10)`, `[-10,0)`, `[0,5)`, `[5,10)`,
  `[10,15)`, and `[15,20)` minutes;
- a main version that keeps locked quotes (`bid = ask`); and
- a robustness version that excludes locked quotes.

The relative quoted spread is measured in basis points:

```text
10,000 * (ask - bid) / ((ask + bid) / 2)
```

Each quote is weighted by the number of seconds for which it is active. A quote
already active when a window begins is included. Crossed quotes (`bid > ask`)
are excluded for their exact active duration without filling the interval with
the previous quote. Missing, zero, or negative prices are excluded and reported
in the diagnostics.

## Repository files

- `wrds_spread_pipeline.Rmd`: current documented analysis workflow.

## 1. Download the repository

Use the green **Code** button on GitHub to download a ZIP, or clone it:

```bash
git clone https://github.com/shuau819/wrds-complete-nbbo-spreads.git
cd wrds-complete-nbbo-spreads
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
run:

```r
usethis::edit_r_environ()
```

Add these lines using your own credentials:

```text
WRDS_USER=your_wrds_username
WRDS_PASSWORD=your_wrds_password
```
Save the file and restart RStudio. 

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
   `Offline self-test passed.` This test does not access WRDS.
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
- `diagnostics.csv`: minute- and window-level coverage, invalid-price,
  locked/crossed-duration, and processing-error information.

`locked_treatment = keep_locked` is the main specification.
`locked_treatment = exclude_locked` is the robustness specification.

In `spreads.csv`, `regression_spread_bps` is populated only when every required
minute has complete two-sided quote coverage. `mean_of_minute_spreads_bps` is
retained for diagnostic review even when strict coverage fails.

## 7. Basic checks before regression

Check `diagnostics.csv` for:

- non-empty `processing_error` values;
- `complete_quote_coverage = FALSE`;
- positive `missing_quote_seconds`, `invalid_price_seconds`, or
  `crossed_seconds`; and
- unusually large `locked_seconds`.

A small crossed interval can make strict coverage false even when it lasts only
a fraction of a second. Keep the computed diagnostic value and decide on the
final regression coverage rule separately rather than deleting observations
without review.

## Data source

- [WRDS Millisecond Intraday Indicators](https://wrds-www.wharton.upenn.edu/pages/get-data/nyse-trade-and-quote/millisecond-trade-and-quote-daily-product-2003-present-updated-daily/taq-millisecond-tools/millisecond-intraday-indicators-by-wrds/)
