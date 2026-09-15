## -----------------------------------------------------------------------------
## fetch.R -- on-demand, single-point driving data for GSI Scout, from ERA5 via
## the Open-Meteo archive API.
##
## Adapted from GrowingSeasonIndex/data-raw/fetch_openmeteo.R (the Glass Box
## project's fetch script, confirmed working against the live API -- see the
## cached .rds files already in that project's data/openmeteo/). That script
## was written for a small fixed site catalog and run as a batch job; this
## version is the same fetch logic reshaped into a function callable from the
## Shiny app for an arbitrary map-clicked point, with the same chunked,
## resumable, unit-asserted design.
##
## fetch_point(lat, lon, year_to) returns one row per day, 1 Jan of
## `year_from` (default 1991) through 31 Dec of `year_to`, with:
##   tmin_c, tmax_c, tmean_c, tdew_c, precip_mm      -- daily
##   vpd_fao56_pa, vpd_native_pa, vpd_native_max_pa  -- three VPD flavors,
##     kept side by side on purpose (see gsi-walkthrough.md) -- which one
##     drives the model is a UI choice made at call time, not fetch time
##   et0_mm, srad_mj, daylight_s, sunshine_s         -- extras, for reference
##   sm_0_7, sm_7_28, sm_28_100                      -- soil moisture, full
##     record (1991-year_to) like everything else, so it gets a real
##     climatology band -- added 2026-09-15, at Mike's request; the Glass Box
##     script this was ported from only fetched these for the two focal
##     years, which is fine for Glass Box's single-year figures but not
##     enough for a climatology
##   rh_mean, rh_min, soilt_0_7
##     -- only populated for `year_to` and the year before it (the "focal"
##        pass); NA in earlier years. Nothing in GSI Scout plots these against
##        a climatology, so there's no reason to pay Open-Meteo's per-variable
##        cost for the full record on them too.
##
## Caching: every point/year-range/variable-set chunk is cached to disk under
## `cache_dir`, keyed by rounded lat/lon, so re-visiting a point (or extending
## its selected year) only fetches what's missing. Cache is NOT wiped between
## app sessions -- deploy this app with the cache directory writable, or
## re-fetches happen on every restart.
## -----------------------------------------------------------------------------

suppressPackageStartupMessages(library(jsonlite))

`%||%` <- if (exists("%||%")) `%||%` else function(a, b) if (is.null(a)) b else a

API   <- "https://archive-api.open-meteo.com/v1/archive"
MODEL <- "era5"   # era5 (0.25 deg, 1940-) | era5_land (0.1 deg, 1950-)

DAILY <- c(
  "temperature_2m_max", "temperature_2m_min", "temperature_2m_mean",
  "precipitation_sum", "et0_fao_evapotranspiration",
  "shortwave_radiation_sum", "daylight_duration", "sunshine_duration"
)
## Soil moisture moved into the LONG pull (2026-09-15, at Mike's request) so
## it gets a real 1991-2020 climatology band like the other variables, not
## just the two focal years. This roughly 2.5x's the cost of the long pass
## (2 variables -> 5, and Open-Meteo's free-tier cost scales with variables x
## period) -- worth it for a climatology, but it means a NEW point's first
## fetch is noticeably slower than before. Relative humidity and soil
## temperature stay focal-only: nothing in this app plots their climatology,
## so there's no reason to pay for 35 years of them.
HOURLY_LONG <- c("dew_point_2m", "vapour_pressure_deficit",
                 "soil_moisture_0_to_7cm", "soil_moisture_7_to_28cm",
                 "soil_moisture_28_to_100cm")
HOURLY_FOCAL <- c(HOURLY_LONG, "relative_humidity_2m", "soil_temperature_0_to_7cm")

#' A filesystem-safe key for a point, rounded to ~100 m so nearby clicks share
#' a cache entry instead of each spawning a fresh multi-decade fetch.
point_key <- function(lat, lon) {
  sprintf("%.3f_%.3f", round(lat, 3), round(lon, 3))
}

#' GET a URL and parse it, surfacing Open-Meteo's own error text. Rate-limit
#' refusals are retried with a growing wait; see fetch_openmeteo.R for why.
api_get <- function(url, tries = 5) {
  for (k in seq_len(tries)) {
    txt <- if (requireNamespace("curl", quietly = TRUE)) {
      rawToChar(curl::curl_fetch_memory(url)$content)
    } else {
      paste(readLines(url, warn = FALSE), collapse = "")
    }
    j <- jsonlite::fromJSON(txt, simplifyVector = TRUE)
    if (!isTRUE(j$error)) return(j)

    rate_limited <- grepl("limit", j$reason %||% "", ignore.case = TRUE)
    if (rate_limited && k < tries) {
      wait <- 65 * k
      message(sprintf("   rate limited -- waiting %ds, then attempt %d of %d",
                      wait, k + 1, tries))
      Sys.sleep(wait)
      next
    }
    stop("Open-Meteo refused the request.\n  reason: ", j$reason %||% "(none given)",
         "\n  url:    ", url, call. = FALSE)
  }
}

build_url <- function(lat, lon, start, end, hourly, model = MODEL) {
  q <- c(
    latitude   = format(lat, digits = 6),
    longitude  = format(lon, digits = 6),
    start_date = start,
    end_date   = end,
    daily      = paste(DAILY,  collapse = ","),
    hourly     = paste(hourly, collapse = ","),
    timezone   = "auto"
  )
  if (nzchar(model)) q["models"] <- model
  paste0(API, "?", paste(names(q), q, sep = "=", collapse = "&"))
}

hourly_to_daily <- function(h) {
  day <- as.Date(substr(h$time, 1, 10))
  ag  <- function(nm, f) {
    if (is.null(h[[nm]])) return(NULL)
    as.numeric(tapply(h[[nm]], day, f, na.rm = TRUE))
  }
  out <- data.frame(date = as.Date(names(tapply(h$time, day, length))))
  add <- function(o, nm, v) { if (!is.null(v)) o[[nm]] <- v; o }
  out <- add(out, "tdew_c",              ag("dew_point_2m", mean))
  out <- add(out, "vpd_native_mean_kpa", ag("vapour_pressure_deficit", mean))
  out <- add(out, "vpd_native_max_kpa",  ag("vapour_pressure_deficit", max))
  out <- add(out, "rh_mean",             ag("relative_humidity_2m", mean))
  out <- add(out, "rh_min",              ag("relative_humidity_2m", min))
  out <- add(out, "sm_0_7",              ag("soil_moisture_0_to_7cm", mean))
  out <- add(out, "sm_7_28",             ag("soil_moisture_7_to_28cm", mean))
  out <- add(out, "sm_28_100",           ag("soil_moisture_28_to_100cm", mean))
  out <- add(out, "soilt_0_7",           ag("soil_temperature_0_to_7cm", mean))
  out
}

#' Fetch one point/year-range/variable-set chunk, or return the cached copy.
fetch_chunk <- function(lat, lon, y0, y1, hourly, tag, chunk_dir, refresh, pause) {
  f <- file.path(chunk_dir, sprintf("%s_%s_%d_%d.rds", point_key(lat, lon), tag, y0, y1))
  if (file.exists(f) && !refresh) return(readRDS(f))

  url <- build_url(lat, lon, sprintf("%d-01-01", y0), sprintf("%d-12-31", y1), hourly)
  j <- api_get(url)

  dly <- as.data.frame(j$daily, stringsAsFactors = FALSE)
  dly$date <- as.Date(dly$time); dly$time <- NULL
  out <- merge(dly, hourly_to_daily(j$hourly), by = "date", all.x = TRUE)

  saveRDS(out, f)
  Sys.sleep(pause)
  out
}

assert_units <- function(d) {
  bad <- function(...) stop(paste0(...), call. = FALSE)
  if (max(d$tmin_c, na.rm = TRUE) > 60)
    bad(sprintf("tmin looks like Kelvin (max %.1f).", max(d$tmin_c, na.rm = TRUE)))
  if (min(d$tmin_c, na.rm = TRUE) < -70) bad("tmin below -70 C: check the variable.")
  if (any(d$tmax_c < d$tmin_c, na.rm = TRUE)) bad("tmax below tmin on at least one day.")
  if (max(d$vpd_fao56_pa, na.rm = TRUE) < 200)
    bad(sprintf("VPD looks like kPa (max %.2f).", max(d$vpd_fao56_pa, na.rm = TRUE)))
  if (any(d$precip_mm < 0, na.rm = TRUE)) bad("negative precipitation.")
  sm <- c(d$sm_0_7, d$sm_7_28, d$sm_28_100)
  if (length(sm) && any(sm > 1.2, na.rm = TRUE))
    bad("soil moisture above 1.2 m3/m3: probably given as a percent.")
  invisible(TRUE)
}

#' Fetch daily driving data for one point, 1 Jan `year_from` through
#' 31 Dec `year_to`. See file header for the returned schema.
#'
#' @param lat,lon decimal degrees (WGS84), from the map click
#' @param year_to last year to fetch (the selected/focal year)
#' @param year_from first year, for the climatology band (default 1991)
#' @param cache_dir where completed per-point series are cached
#' @param refresh if TRUE, ignore any cache and re-fetch everything
#' @param progress optional function(message) called with a status string
#'   before each network chunk -- wire to a Shiny progress bar or withProgress
fetch_point <- function(lat, lon, year_to, year_from = 1991,
                        cache_dir = "data/cache", refresh = FALSE,
                        chunk_years = 5, pause_seconds = 3, progress = NULL) {
  stopifnot(year_to >= year_from)
  say <- function(msg) if (is.function(progress)) progress(msg) else message(msg)

  chunk_dir <- file.path(cache_dir, ".chunks")
  dir.create(chunk_dir, recursive = TRUE, showWarnings = FALSE)

  final_f <- file.path(cache_dir, sprintf("%s_%d_%d.rds",
                                          point_key(lat, lon), year_from, year_to))
  if (file.exists(final_f) && !refresh) {
    say("Using cached data for this point/year range.")
    return(readRDS(final_f))
  }

  say(sprintf("Fetching %d-%d for %.3f, %.3f ...", year_from, year_to, lat, lon))

  starts <- seq(year_from, year_to, by = chunk_years)
  g <- do.call(rbind, lapply(starts, function(y0) {
    y1 <- min(y0 + chunk_years - 1, year_to)
    say(sprintf("  temperature / VPD / daylength, %d-%d", y0, y1))
    fetch_chunk(lat, lon, y0, y1, HOURLY_LONG, "long", chunk_dir, refresh, pause_seconds)
  }))
  g <- g[order(g$date), ]

  focal_from <- max(year_from, year_to - 1)
  say(sprintf("  soil moisture / humidity, %d-%d", focal_from, year_to))
  fx <- fetch_chunk(lat, lon, focal_from, year_to, HOURLY_FOCAL, "focal",
                    chunk_dir, refresh, pause_seconds)

  # Only rh/soil-temperature come from the focal pass now -- sm_0_7 etc. are
  # already in `g` from the long pull (see HOURLY_LONG above) and must NOT be
  # overwritten here, or the climatology gets clobbered back down to
  # focal-years-only.
  extra <- c("rh_mean", "rh_min", "soilt_0_7")
  i <- match(g$date, fx$date)
  for (v in extra) g[[v]] <- if (is.null(fx[[v]])) NA_real_ else fx[[v]][i]

  d <- data.frame(
    date      = g$date,
    year      = as.integer(format(g$date, "%Y")),
    doy       = as.integer(format(g$date, "%j")),
    tmin_c    = round(g$temperature_2m_min, 2),
    tmax_c    = round(g$temperature_2m_max, 2),
    tmean_c   = round(g$temperature_2m_mean, 2),
    tdew_c    = round(g$tdew_c, 2),
    precip_mm = round(g$precipitation_sum, 2),
    stringsAsFactors = FALSE
  )

  # Three VPDs, kept side by side -- which drives the model is a UI choice
  # (scout_defaults()$vpd_driver), not baked in at fetch time.
  d$vpd_fao56_pa      <- round(vpd_from_temps(d$tmax_c, d$tmin_c, d$tdew_c), 1)
  d$vpd_native_pa     <- round(g$vpd_native_mean_kpa * 1000, 1)
  d$vpd_native_max_pa <- round(g$vpd_native_max_kpa  * 1000, 1)

  d$et0_mm     <- round(g$et0_fao_evapotranspiration, 2)
  d$srad_mj    <- round(g$shortwave_radiation_sum, 2)
  d$daylight_s <- round(g$daylight_duration, 0)
  d$sunshine_s <- round(g$sunshine_duration, 0)
  d$rh_mean    <- round(g$rh_mean, 1)
  d$rh_min     <- round(g$rh_min, 1)
  d$sm_0_7     <- round(g$sm_0_7, 4)
  d$sm_7_28    <- round(g$sm_7_28, 4)
  d$sm_28_100  <- round(g$sm_28_100, 4)
  d$soilt_0_7  <- round(g$soilt_0_7, 2)

  assert_units(d)
  saveRDS(d, final_f)
  say(sprintf("Done -- %s days.", format(nrow(d), big.mark = ",")))
  d
}

#' VPD column name for a scout_defaults()$vpd_driver value.
vpd_driver_col <- function(driver) {
  switch(driver,
    fao56       = "vpd_fao56_pa",
    native_mean = "vpd_native_pa",
    native_max  = "vpd_native_max_pa",
    stop("vpd_driver must be fao56, native_mean or native_max")
  )
}
