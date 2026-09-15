## -----------------------------------------------------------------------------
## make_sample_cache.R -- generate a SYNTHETIC driving-data cache for GSI
## Scout's default point (Tucson, 32.22 N / -110.93 W), so UI/layout work
## never has to re-hit Open-Meteo.
##
## This is NOT real ERA5 data. It's a hand-built seasonal cycle (with noise)
## shaped like Tucson's climate -- warm/dry foresummer, a monsoon bump in
## soil moisture and precipitation, a cold winter dip -- good enough to
## exercise every plot, sub-index, phase transition and FEMS-ghost overlay
## realistically, but NOT good enough to draw any actual conclusion from.
## Never use this for anything but iterating on layout/UI.
##
## Run once with:  Rscript data-raw/make_sample_cache.R
##
## What it does: writes one file per selectable year (1991-2025) directly
## into data/cache/, in the exact format fetch_point() itself would have
## written (see R/fetch.R's `final_f` naming and column schema). fetch_point()
## checks that cache BEFORE touching the network, so as long as you're
## working at the default point (or click back to it -- see the "Snap to
## test point" button added to app.R alongside this), every "Get data for
## this point" click for any year is an instant local read. Delete these
## files (or check "ignore cache") whenever you want real data back for that
## point.
## -----------------------------------------------------------------------------

source("R/fetch.R")   # for point_key(), assert_units(), vpd_from_temps() via gsi.R
source("R/gsi.R")     # vpd_from_temps()

TEST_LAT <- 32.22
TEST_LON <- -110.93
YEAR_FROM <- 1991
YEAR_TO_MAX <- 2025
CACHE_DIR <- "data/cache"

set.seed(20260915)  # reproducible -- same "test data" every time this is rerun

dates <- seq(as.Date(sprintf("%d-01-01", YEAR_FROM)),
             as.Date(sprintf("%d-12-31", YEAR_TO_MAX)), by = "day")
n <- length(dates)
doy <- as.integer(format(dates, "%j"))
yr  <- as.integer(format(dates, "%Y"))

# Day-of-year angle, peaking at summer solstice (~doy 172)
ang <- 2 * pi * (doy - 172) / 365.25

## Temperature: Tucson-shaped annual cycle + a little year-to-year drift +
## daily noise. tmax always a few degrees above tmean; tmin a few below.
tmean <- 21 + 12 * cos(ang) + 0.03 * (yr - YEAR_FROM) + rnorm(n, 0, 2.2)
tmax  <- tmean + 9 + rnorm(n, 0, 1.3)
tmin  <- tmean - 8 + rnorm(n, 0, 1.3)
tdew  <- tmin - 8 + 10 * pmax(0, cos(ang + pi * 0.55)) + rnorm(n, 0, 2)  # damp, bumps up in monsoon

## Precipitation: two bumps -- winter frontal (small) + summer monsoon (big),
## both as a thinned Poisson-ish spike process, mm/day.
monsoon_w   <- pmax(0, cos(ang + pi * 0.62))^6        # sharp Jul-Sep bump
winter_w    <- pmax(0, cos(ang - pi))^3 * 0.4          # broader, weaker Dec-Feb bump
rain_chance <- 0.06 + 0.35 * monsoon_w + 0.12 * winter_w
precip_mm <- ifelse(runif(n) < rain_chance,
                    round(rexp(n, rate = 1 / (4 + 18 * monsoon_w)), 1), 0)

## Soil moisture (m3/m3): dries down through the May-June foresummer, spikes
## with the monsoon, decays through fall/winter. Shallow layer tracks rain
## fastest; deeper layers are damped/lagged versions.
dry_season   <- pmax(0, cos(ang + pi * 0.15))          # low near doy ~172 minus offset
sm_base      <- 0.10 + 0.05 * cos(ang - pi * 0.05)
rain_carry   <- as.numeric(stats::filter(precip_mm, filter = 0.55^(0:20), sides = 1))
rain_carry[is.na(rain_carry)] <- 0
sm_0_7   <- pmin(0.42, pmax(0.03, sm_base - 0.05 * dry_season + 0.006 * rain_carry + rnorm(n, 0, 0.01)))
sm_7_28  <- pmin(0.40, pmax(0.04, sm_base - 0.03 * dry_season + 0.004 * rain_carry + rnorm(n, 0, 0.006)))
sm_28_100<- pmin(0.38, pmax(0.05, sm_base - 0.015 * dry_season + 0.002 * rain_carry + rnorm(n, 0, 0.004)))
soilt_0_7 <- round(tmean + 2 + rnorm(n, 0, 1), 2)

## Daylength/sun geometry: reuse gsi.R's own daylength machinery so this
## matches the app's photoperiod sub-index exactly (geometric convention).
daylight_s <- photoperiod_seconds(doy, TEST_LAT, method = "geometric")
sunshine_s <- pmax(0, daylight_s - rnorm(n, 1800, 1200))

## Radiation and ET0: rough, physically-ordered stand-ins, not a real energy
## balance -- fine for exercising the reference plots only.
srad_mj <- pmax(2, 20 + 10 * cos(ang) - 6 * pmin(1, rain_carry / 20) + rnorm(n, 0, 1.5))
et0_mm  <- pmax(0.3, 3.5 + 3 * cos(ang) - 0.15 * sm_0_7 * 30 + rnorm(n, 0, 0.4))

## Humidity, for reference plots only.
rh_mean <- pmin(95, pmax(5, 35 + 30 * pmax(0, cos(ang + pi * 0.6)) - 0.5 * (tmax - tmean) + rnorm(n, 0, 5)))
rh_min  <- pmin(rh_mean - 2, pmax(2, rh_mean - 25 - rnorm(n, 5, 4)))

d <- data.frame(
  date      = dates,
  year      = yr,
  doy       = doy,
  tmin_c    = round(tmin, 2),
  tmax_c    = round(pmax(tmax, tmin + 1), 2),
  tmean_c   = round(tmean, 2),
  tdew_c    = round(pmin(tdew, tmin), 2),
  precip_mm = round(precip_mm, 2),
  stringsAsFactors = FALSE
)

d$vpd_fao56_pa      <- round(vpd_from_temps(d$tmax_c, d$tmin_c, d$tdew_c), 1)
# Native (ERA5-hourly-derived) VPD flavors: mean a bit below the FAO-56
# daily-range estimate, max well above it -- same relative shape real ERA5
# output has in the Glass Box cache files.
d$vpd_native_pa     <- round(pmax(20, d$vpd_fao56_pa * runif(n, 0.55, 0.85)), 1)
d$vpd_native_max_pa <- round(d$vpd_fao56_pa * runif(n, 1.3, 1.9), 1)

d$et0_mm     <- round(et0_mm, 2)
d$srad_mj    <- round(srad_mj, 2)
d$daylight_s <- round(daylight_s, 0)
d$sunshine_s <- round(sunshine_s, 0)
d$rh_mean    <- round(rh_mean, 1)
d$rh_min     <- round(rh_min, 1)
d$sm_0_7     <- round(sm_0_7, 4)
d$sm_7_28    <- round(sm_7_28, 4)
d$sm_28_100  <- round(sm_28_100, 4)
d$soilt_0_7  <- round(soilt_0_7, 2)

assert_units(d)  # same sanity gate fetch_point() itself runs

dir.create(CACHE_DIR, recursive = TRUE, showWarnings = FALSE)
key <- point_key(TEST_LAT, TEST_LON)

written <- 0
for (year_to in YEAR_FROM:YEAR_TO_MAX) {
  f <- file.path(CACHE_DIR, sprintf("%s_%d_%d.rds", key, YEAR_FROM, year_to))
  saveRDS(d[d$year <= year_to, ], f)
  written <- written + 1
}

message(sprintf(
  "Wrote %d sample cache files for %.3f, %.3f (key %s) to %s/ -- covers every year %d-%d.",
  written, TEST_LAT, TEST_LON, key, CACHE_DIR, YEAR_FROM, YEAR_TO_MAX))
message("This is SYNTHETIC data for UI testing only -- see this script's header.")
