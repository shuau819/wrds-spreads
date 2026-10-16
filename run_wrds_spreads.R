#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(data.table))

WINDOWS <- data.table(
  window = c("m30_m10", "m10_0", "0_5", "5_10", "10_15", "15_20"),
  start_min = c(-30, -10, 0, 5, 10, 15),
  end_min = c(-10, 0, 5, 10, 15, 20)
)

parse_args <- function(args) {
  out <- list(
    input = "input.csv",
    output_dir = "run_output",
    test_xlk = FALSE,
    self_test = FALSE
  )
  i <- 1L
  while (i <= length(args)) {
    key <- args[[i]]
    if (key == "--test-xlk") {
      out$test_xlk <- TRUE
      i <- i + 1L
    } else if (key == "--self-test") {
      out$self_test <- TRUE
      i <- i + 1L
    } else if (key %in% c("--input", "--output-dir")) {
      if (i == length(args)) stop("Missing value after ", key)
      name <- sub("^--", "", key)
      name <- gsub("-", "_", name)
      out[[name]] <- args[[i + 1L]]
      i <- i + 2L
    } else {
      stop("Unknown argument: ", key)
    }
  }
  out
}

clock_to_seconds <- function(x) {
  parts <- strsplit(as.character(x), ":", fixed = TRUE)[[1L]]
  if (length(parts) != 3L) stop("anchor_time must be HH:MM:SS")
  values <- suppressWarnings(as.numeric(parts))
  if (anyNA(values) || values[1L] < 0 || values[1L] >= 24 ||
      values[2L] < 0 || values[2L] >= 60 ||
      values[3L] < 0 || values[3L] >= 60) {
    stop("Invalid anchor_time: ", x)
  }
  values[1L] * 3600 + values[2L] * 60 + values[3L]
}

seconds_to_clock <- function(x) {
  if (x < 0 || x >= 86400) stop("Requested windows cross midnight")
  h <- floor(x / 3600)
  m <- floor((x %% 3600) / 60)
  s <- x %% 60
  sprintf("%02d:%02d:%09.6f", h, m, s)
}

validate_input <- function(x) {
  required <- c("ticker", "date", "anchor_time", "day_type", "matched_event_date")
  missing_cols <- setdiff(required, names(x))
  if (length(missing_cols)) {
    stop("Input is missing columns: ", paste(missing_cols, collapse = ", "))
  }
  x[, input_row := .I]
  x[, ticker := toupper(trimws(as.character(ticker)))]
  x[, date := as.IDate(date)]
  x[, matched_event_date := as.IDate(matched_event_date)]
  x[, anchor_time := trimws(as.character(anchor_time))]
  x[, day_type := tolower(trimws(as.character(day_type)))]
  if (anyNA(x$date)) stop("At least one date is invalid; use YYYY-MM-DD")
  if (anyNA(x$matched_event_date)) stop("At least one matched_event_date is invalid")
  if (any(!x$day_type %chin% c("event", "comparison"))) {
    stop("day_type must be event or comparison")
  }
  if (any(!grepl("^[A-Z0-9-]{1,15}$", x$ticker))) {
    stop("ticker must be a root ticker without a suffix")
  }
  x
}

connect_wrds <- function() {
  if (!requireNamespace("DBI", quietly = TRUE) ||
      !requireNamespace("RPostgres", quietly = TRUE)) {
    stop("Install DBI and RPostgres before connecting to WRDS")
  }
  user <- Sys.getenv("WRDS_USER")
  password <- Sys.getenv("WRDS_PASSWORD")
  if (!nzchar(user) || !nzchar(password)) {
    stop("Set WRDS_USER and WRDS_PASSWORD in ~/.Renviron, then restart R")
  }
  DBI::dbConnect(
    RPostgres::Postgres(),
    host = "wrds-pgdata.wharton.upenn.edu",
    port = 9737,
    dbname = "wrds",
    sslmode = "require",
    user = user,
    password = password
  )
}

fetch_complete_nbbo <- function(con, ticker, date, start_sec, end_sec) {
  year <- format(as.IDate(date), "%Y")
  ymd <- format(as.IDate(date), "%Y%m%d")
  schema <- paste0("taqm_", year)
  table <- paste0("complete_nbbo_", ymd)
  start_clock <- seconds_to_clock(start_sec)
  end_clock <- seconds_to_clock(end_sec)

  sql <- sprintf(
    paste(
      "WITH prior AS (",
      "  SELECT date, time_m, EXTRACT(EPOCH FROM time_m)::double precision AS time_sec,",
      "         sym_root, best_bid::double precision AS best_bid,",
      "         best_ask::double precision AS best_ask",
      "  FROM %s.%s",
      "  WHERE sym_root = %s AND COALESCE(sym_suffix, '') = ''",
      "    AND time_m <= TIME %s",
      "  ORDER BY time_m DESC LIMIT 1",
      "), inside_window AS (",
      "  SELECT date, time_m, EXTRACT(EPOCH FROM time_m)::double precision AS time_sec,",
      "         sym_root, best_bid::double precision AS best_bid,",
      "         best_ask::double precision AS best_ask",
      "  FROM %s.%s",
      "  WHERE sym_root = %s AND COALESCE(sym_suffix, '') = ''",
      "    AND time_m > TIME %s AND time_m < TIME %s",
      ")",
      "SELECT * FROM prior UNION ALL SELECT * FROM inside_window ORDER BY time_sec",
      sep = "\n"
    ),
    schema, table, DBI::dbQuoteString(con, ticker), DBI::dbQuoteString(con, start_clock),
    schema, table, DBI::dbQuoteString(con, ticker),
    DBI::dbQuoteString(con, start_clock), DBI::dbQuoteString(con, end_clock)
  )
  as.data.table(DBI::dbGetQuery(con, sql))
}

classify_state <- function(bid, ask) {
  fcase(
    is.na(bid) | is.na(ask), "missing_price",
    !is.finite(bid) | !is.finite(ask) | bid <= 0 | ask <= 0, "invalid_price",
    bid > ask, "crossed",
    bid == ask, "locked",
    bid < ask, "valid",
    default = "invalid_price"
  )
}

calculate_windows <- function(quotes, anchor_sec) {
  global_start <- anchor_sec + min(WINDOWS$start_min) * 60
  global_end <- anchor_sec + max(WINDOWS$end_min) * 60
  quotes <- copy(as.data.table(quotes))
  quotes <- quotes[is.finite(time_sec) & time_sec < global_end]
  setorder(quotes, time_sec)

  # At identical timestamps, the last returned state becomes active.
  if (nrow(quotes)) quotes <- quotes[, .SD[.N], by = time_sec]

  if (!nrow(quotes)) {
    states <- data.table(
      state_start = global_start,
      state_end = global_end,
      state = "missing_quote",
      spread_bps = NA_real_
    )
  } else {
    quotes[, state_start := pmax(time_sec, global_start)]
    quotes[, state_end := shift(time_sec, type = "lead", fill = global_end)]
    quotes[, state_end := pmin(state_end, global_end)]
    quotes <- quotes[state_end > state_start]
    quotes[, state := classify_state(best_bid, best_ask)]
    quotes[, spread_bps := fifelse(
      state %chin% c("valid", "locked"),
      10000 * (best_ask - best_bid) / ((best_ask + best_bid) / 2),
      NA_real_
    )]
    states <- quotes[, .(state_start, state_end, state, spread_bps)]
    if (!nrow(states) || states$state_start[1L] > global_start) {
      first_start <- if (nrow(states)) states$state_start[1L] else global_end
      states <- rbind(
        data.table(state_start = global_start, state_end = first_start,
                   state = "missing_quote", spread_bps = NA_real_),
        states
      )
    }
  }

  rbindlist(lapply(seq_len(nrow(WINDOWS)), function(i) {
    w <- WINDOWS[i]
    ws <- anchor_sec + w$start_min * 60
    we <- anchor_sec + w$end_min * 60
    overlap <- states[
      state_end > ws & state_start < we,
      .(state, spread_bps,
        seconds = pmax(0, pmin(state_end, we) - pmax(state_start, ws)))
    ][seconds > 0]
    duration <- we - ws
    duration_for <- function(label) sum(overlap[state == label, seconds])
    valid_seconds <- sum(overlap[state %chin% c("valid", "locked"), seconds])
    numerator <- sum(overlap[state %chin% c("valid", "locked"), spread_bps * seconds], na.rm = TRUE)
    data.table(
      window = w$window,
      window_start_min = w$start_min,
      window_end_min = w$end_min,
      total_seconds = duration,
      tw_relative_quoted_spread_bps = if (valid_seconds > 0) numerator / valid_seconds else NA_real_,
      valid_seconds = valid_seconds,
      missing_quote_seconds = duration_for("missing_quote"),
      missing_price_seconds = duration_for("missing_price"),
      invalid_price_seconds = duration_for("invalid_price"),
      locked_seconds = duration_for("locked"),
      crossed_seconds = duration_for("crossed"),
      excluded_seconds = duration - valid_seconds,
      valid_coverage_pct = 100 * valid_seconds / duration
    )
  }))
}

empty_result_for_error <- function(message) {
  ans <- copy(WINDOWS)
  setnames(ans, c("start_min", "end_min"), c("window_start_min", "window_end_min"))
  ans[, `:=`(
    total_seconds = (window_end_min - window_start_min) * 60,
    tw_relative_quoted_spread_bps = NA_real_,
    valid_seconds = 0,
    missing_quote_seconds = NA_real_,
    missing_price_seconds = NA_real_,
    invalid_price_seconds = NA_real_,
    locked_seconds = NA_real_,
    crossed_seconds = NA_real_,
    excluded_seconds = NA_real_,
    valid_coverage_pct = 0,
    processing_error = message
  )]
  ans
}

process_one <- function(con, row) {
  metadata <- row[, .(input_row, ticker, date, anchor_time, day_type, matched_event_date)]
  tryCatch({
    anchor_sec <- clock_to_seconds(row$anchor_time)
    global_start <- anchor_sec - 30 * 60
    global_end <- anchor_sec + 20 * 60
    seconds_to_clock(global_start)
    seconds_to_clock(global_end)
    quotes <- fetch_complete_nbbo(con, row$ticker, row$date, global_start, global_end)
    result <- calculate_windows(quotes, anchor_sec)
    result[, processing_error := ""]
    cbind(metadata[rep(1L, nrow(result))], result)
  }, error = function(e) {
    result <- empty_result_for_error(conditionMessage(e))
    cbind(metadata[rep(1L, nrow(result))], result)
  })
}

run_self_test <- function() {
  # Anchor 14:00. A valid quote is already active at 13:30. A crossed quote
  # occupies 13:55-14:00 and must not be backfilled. A locked quote is retained.
  anchor <- 14 * 3600
  synthetic <- data.table(
    time_sec = c(13 * 3600 + 20 * 60, 13 * 3600 + 40 * 60,
                 13 * 3600 + 55 * 60, 14 * 3600,
                 14 * 3600 + 5 * 60),
    best_bid = c(99, 100, 102, 101, 102),
    best_ask = c(101, 102, 101, 101, 103)
  )
  got <- calculate_windows(synthetic, anchor)
  stopifnot(got[window == "m30_m10", valid_seconds] == 1200)
  stopifnot(got[window == "m10_0", crossed_seconds] == 300)
  stopifnot(got[window == "m10_0", valid_seconds] == 300)
  stopifnot(got[window == "0_5", locked_seconds] == 300)
  stopifnot(got[window == "0_5", tw_relative_quoted_spread_bps] == 0)
  message("Self-test passed")
}

main <- function() {
  args <- parse_args(commandArgs(trailingOnly = TRUE))
  if (args$self_test) {
    run_self_test()
    return(invisible(NULL))
  }
  input <- validate_input(fread(args$input, colClasses = "character"))
  if (args$test_xlk) {
    input <- input[ticker == "XLK" & date == as.IDate("2019-01-30") & anchor_time == "14:00:00"]
    if (nrow(input) != 1L) stop("--test-xlk requires exactly one XLK 2019-01-30 14:00:00 input row")
  }

  dir.create(args$output_dir, recursive = TRUE, showWarnings = FALSE)
  con <- connect_wrds()
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  results <- rbindlist(lapply(seq_len(nrow(input)), function(i) {
    message("Processing row ", i, "/", nrow(input), ": ", input$ticker[i], " ", input$date[i])
    process_one(con, input[i])
  }), fill = TRUE)

  spread_columns <- c(
    "input_row", "ticker", "date", "anchor_time", "day_type", "matched_event_date",
    "window", "window_start_min", "window_end_min", "tw_relative_quoted_spread_bps"
  )
  diagnostic_columns <- c(
    "input_row", "ticker", "date", "anchor_time", "day_type", "matched_event_date",
    "window", "total_seconds", "valid_seconds", "missing_quote_seconds",
    "missing_price_seconds", "invalid_price_seconds", "locked_seconds",
    "crossed_seconds", "excluded_seconds", "valid_coverage_pct", "processing_error"
  )
  fwrite(results[, ..spread_columns], file.path(args$output_dir, "spreads.csv"), na = "")
  fwrite(results[, ..diagnostic_columns], file.path(args$output_dir, "diagnostics.csv"), na = "")
  message("Wrote: ", normalizePath(args$output_dir))
}

if (sys.nframe() == 0L) main()
