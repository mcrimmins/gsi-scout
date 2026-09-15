## -----------------------------------------------------------------------------
## gsi.R -- Growing Season Index model, as pure functions. GSI Scout's copy.
##
## Ported from the GrowingSeasonIndex / Glass Box project's R/gsi.R (same repo
## that has gsi-glassbox and gsi-walkthrough.qmd) and extended for GSI Scout:
##
##   - a soil-moisture sub-index (idx_soilm()), toggleable like precipitation
##   - a 2-phase greenup/dormant classifier (gsi_phase2()) in place of Glass
##     Box's 5-state greenup/maintenance/senescence/cured machine -- Cheryl's
##     call (convo_on_gsi.docx): let drought push a site back to dormancy at
##     any point, rather than requiring it to pass through an explicit
##     maintenance window first. See claude/gsi-pointapp-scope.md for why the
##     two apps are allowed to disagree here.
##   - scout_defaults(), seeded from the FEMS operational parameter table
##     (also convo_on_gsi.docx) rather than the NFDRS2016 literature defaults
##     gsi_defaults() used in Glass Box. FEMS's numbers are NOT the same as
##     the base NFDRS2016 defaults -- e.g. VPD 1956-3882 Pa here vs. 900-4100
##     Pa there -- which is exactly the "how far has local tuning drifted from
##     the national default" question this app exists to make visible.
##
## Baseline model follows Jolly, Nemani & Running (2005) Glob Change Biol
## 11:619-632 and the NFDRS2016 implementation (NWCG). Precipitation control
## follows Daham et al. (2018) J Water Clim Change. Soil moisture is GSI
## Scout's own extension -- not in NFDRS2016 or FEMS, an open research
## question Cheryl and Nick raised, not an established control.
##
## Nothing here knows about Shiny. Everything is vectorised over a day series.
## -----------------------------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- generic linear ramp -----------------------------------------------------

#' Linear ramp bounded to [0, 1]
#' @param x numeric vector
#' @param lo value at which the index is 0 (or 1 if decreasing)
#' @param hi value at which the index is 1 (or 0 if decreasing)
#' @param decreasing if TRUE the index falls from 1 at `lo` to 0 at `hi`
gsi_ramp <- function(x, lo, hi, decreasing = FALSE) {
  if (isTRUE(all.equal(lo, hi))) {
    y <- as.numeric(x >= hi)
  } else {
    y <- pmin(1, pmax(0, (x - lo) / (hi - lo)))
  }
  if (decreasing) 1 - y else y
}

# ---- individual indicator functions -----------------------------------------

#' Minimum temperature indicator. FEMS default: -2 C to 5 C.
idx_tmin <- function(tmin_c, lo = -2, hi = 5) {
  gsi_ramp(tmin_c, lo, hi)
}

#' Vapour pressure deficit indicator. FEMS default: 1956 Pa to 3882 Pa.
#' Decreasing: unconstrained below `lo`, fully limiting above `hi`.
idx_vpd <- function(vpd_pa, lo = 1956, hi = 3882) {
  gsi_ramp(vpd_pa, lo, hi, decreasing = TRUE)
}

#' Photoperiod indicator. FEMS default: 39600 s (11 h) to 43200 s (12 h).
idx_photo <- function(photo_s, lo = 39600, hi = 43200) {
  gsi_ramp(photo_s, lo, hi)
}

#' Precipitation indicator (Daham et al. 2018), generalised.
#' FEMS default: 28-day running total, limiting at/below 0.4 in (10.16 mm),
#' unconstrained at/above 0.8 in (20.32 mm). Off by default -- see
#' scout_defaults()$use_precip.
idx_precip <- function(precip_mm, window = 28, lo = 10.16, hi = 20.32) {
  acc <- roll_sum_trailing(precip_mm, window)
  gsi_ramp(acc, lo, hi)
}

#' Soil moisture indicator -- GSI Scout's own addition, not in NFDRS2016 or
#' FEMS. Volumetric water content (m3/m3), from ERA5 via Open-Meteo at one of
#' three depths (see fetch.R): 0-7 cm, 7-28 cm, or 28-100 cm. Which depth
#' suits herbaceous vs. woody fuels is exactly the open question Cheryl and
#' Nick want to explore with this tool -- it is a UI control, not a constant.
#' Off by default -- see scout_defaults()$use_soilm.
idx_soilm <- function(sm_frac, lo = 0.10, hi = 0.25) {
  gsi_ramp(sm_frac, lo, hi)
}

# ---- rolling helpers ---------------------------------------------------------

roll_sum_trailing <- function(x, n) {
  x[is.na(x)] <- 0
  cs <- c(0, cumsum(x))
  idx <- seq_along(x)
  lo <- pmax(0L, idx - n)
  cs[idx + 1L] - cs[lo + 1L]
}

roll_mean_trailing <- function(x, n) {
  x0 <- x; x0[is.na(x0)] <- 0
  cs <- c(0, cumsum(x0))
  idx <- seq_along(x)
  lo <- pmax(0L, idx - n)
  (cs[idx + 1L] - cs[lo + 1L]) / (idx - lo)
}

# ---- photoperiod -------------------------------------------------------------

#' Sun-elevation offsets defining the end of "day", in degrees below horizon.
PHOTO_CONVENTIONS <- c(
  geometric      =  0.000,  # sun centre on the horizon; FAO-56 / Allen et al.
  sunrise_sunset = -0.833,  # sun's upper limb + refraction: published daylength
  civil_twilight = -6.000   # usable light; arguably the biological cue
)

#' Daylength in seconds from day-of-year and latitude.
#'
#' `method = "geometric"` reproduces the FAO-56 relation and is the formulation
#' Jolly et al. (2005) and Daham et al. (2018) actually use -- GSI Scout's
#' default, chosen (2026-09-14) to match the literature over the alternative
#' of numerically matching FEMS's threshold band. That means the seeded FEMS
#' Day Length ramp (11-12 h) will NOT sit naturally against geometric
#' daylength values for many sites -- geometric daylength never reaches 11 h
#' in the desert Southwest in winter. That's intentional: it's the same
#' "here's where the national default doesn't fit the West" moment the FEMS
#' overlay exists to surface, not a bug. See claude/gsi-pointapp-scope.md.
#'
#' The convention stays a UI selector precisely because it is not a cosmetic
#' choice: at Tucson (32.2 N) the December solstice is 9.89 h geometric,
#' 10.04 h sunrise-to-sunset, 10.94 h civil twilight -- and against an 11 h
#' threshold floor that choice alone decides whether iPhoto forces GSI to
#' zero across the desert Southwest every winter.
photoperiod_seconds <- function(doy, lat_deg,
                                method = c("geometric", "sunrise_sunset",
                                           "civil_twilight")) {
  method <- match.arg(method)
  h0    <- PHOTO_CONVENTIONS[[method]] * pi / 180
  phi   <- lat_deg * pi / 180
  delta <- 0.409 * sin(2 * pi / 365 * doy - 1.39)
  arg   <- (sin(h0) - sin(phi) * sin(delta)) / (cos(phi) * cos(delta))
  ws    <- acos(pmin(1, pmax(-1, arg)))
  (24 / pi) * ws * 3600
}

# ---- vapour pressure deficit -------------------------------------------------

#' Saturation vapour pressure (kPa) from temperature (C), Tetens/FAO-56.
svp_kpa <- function(t_c) 0.6108 * exp(17.27 * t_c / (t_c + 237.3))

#' Daily VPD (Pa) from Tmax, Tmin and dewpoint, FAO-56 convention:
#' es = mean of saturation vp at Tmax and Tmin; ea = saturation vp at Tdew.
vpd_from_temps <- function(tmax_c, tmin_c, tdew_c) {
  es <- (svp_kpa(tmax_c) + svp_kpa(tmin_c)) / 2
  ea <- svp_kpa(tdew_c)
  pmax(0, es - ea) * 1000
}

# ---- combination & smoothing --------------------------------------------------

#' Combine sub-indices into the daily index. "product" is the Jolly/NFDRS2016
#' form and FEMS's operational form -- kept as the only wired-up option in the
#' scout UI for v1, but the model supports the alternatives Glass Box explores.
gsi_combine <- function(idx, method = c("product", "min", "geometric", "weighted"),
                        weights = NULL) {
  method <- match.arg(method)
  k <- length(idx)
  switch(method,
    product   = Reduce(`*`, idx),
    min       = do.call(pmin, idx),
    geometric = Reduce(`*`, idx)^(1 / k),
    weighted  = {
      w <- if (is.null(weights)) rep(1, k) else rep_len(weights, k)
      Reduce(`+`, Map(function(v, wi) v * wi, idx, w)) / sum(w)
    }
  )
}

#' Smooth the daily index. FEMS default: 28-day trailing mean.
gsi_smooth <- function(x, window = 28) roll_mean_trailing(x, window)

# ---- phenophase: 2-phase (greenup / dormant) ---------------------------------

PHASES2 <- c("dormant", "greenup")

#' Classify each day into greenup vs. dormant.
#'
#' GSI Scout's phase model, distinct from Glass Box's 5-state machine (see
#' PHASES there: dormant/greenup/maintenance/senescence/cured). Cheryl's ask,
#' directly: let drought -- which acts through the precip/soil-moisture
#' sub-indices when enabled -- push a site back into dormancy at any point,
#' rather than requiring it to pass through an explicit maintenance window
#' first. One threshold (`greenup`) governs both directions; `persist`
#' requires a run of consecutive days on the far side before the phase
#' actually flips, so single-day noise near the threshold doesn't flicker it.
#'
#' A side benefit of the 2-state design: unlike Glass Box's `cured` state,
#' `dormant` here is never absorbing, so a bimodal site (e.g. the Southwest's
#' cool-season/monsoon double green-up) is represented without needing an
#' explicit "multiple seasons" switch -- it falls out of the model for free.
#'
#' @param gsi_rel GSI / GSImax, in [0, 1]
#' @param greenup relative-GSI threshold separating the two phases (FEMS: 0.3)
#' @param persist consecutive days required on the far side of `greenup`
#'   before the phase actually switches
gsi_phase2 <- function(gsi_rel, greenup = 0.3, persist = 3) {
  n <- length(gsi_rel)
  st <- character(n)
  s <- "dormant"
  run <- 0L
  for (t in seq_len(n)) {
    want <- if (gsi_rel[t] >= greenup) "greenup" else "dormant"
    if (identical(want, s)) {
      run <- 0L
    } else {
      run <- run + 1L
      if (run >= persist) { s <- want; run <- 0L }
    }
    st[t] <- s
  }
  factor(st, levels = PHASES2)
}

#' Start indices of each distinct green-up pulse in a phase series.
greenup_pulses <- function(phase) {
  is_gu <- phase == "greenup"
  which(is_gu & c(TRUE, !is_gu[-length(is_gu)]))
}

# ---- live fuel moisture ------------------------------------------------------

#' Map relative GSI to live fuel moisture. FEMS defaults: herbaceous 30-250 %,
#' woody 60-200 %. See the note in the Glass Box copy of this file for why the
#' single-curve rescaling matters -- unchanged here.
#'
#' @param gate if TRUE, hold at the minimum whenever the site is dormant.
gsi_to_lfm <- function(gsi_rel, phase, lo, hi, gate = TRUE) {
  v <- lo + (hi - lo) * gsi_rel
  if (gate) v[phase == "dormant"] <- lo
  v
}

#' Fraction of live herbaceous load transferred to 1-h dead.
herb_load_transfer <- function(lhfm, full = 30, none = 120) {
  pmin(1, pmax(0, (none - lhfm) / (none - full)))
}

# ---- parameters --------------------------------------------------------------

#' FEMS-seeded default parameter set for GSI Scout.
#'
#' Source: Cheryl's FEMS operational parameter reference (photographed table,
#' convo_on_gsi.docx), transcribed in claude/gsi-pointapp-scope.md. This is
#' NOT gsi_defaults() from Glass Box -- these are FEMS's tuned operational
#' values, which differ from the NFDRS2016 literature defaults Glass Box
#' seeds on (most visibly: VPD 1956-3882 Pa here vs. 900-4100 Pa there).
#'
#' Every value here is a UI seed, not a constant baked into the model --
#' run_gsi() takes the full parameter list and nothing defaults silently.
scout_defaults <- function() {
  list(
    tmin_lo = -2, tmin_hi = 5,
    vpd_lo = 1956, vpd_hi = 3882, vpd_driver = "native_max",  # FEMS: "VPD max"
    photo_lo = 39600, photo_hi = 43200, photo_method = "geometric",  # FAO-56
    use_precip = FALSE, precip_window = 28, precip_lo = 10.16, precip_hi = 20.32,
    use_soilm = FALSE, soilm_depth = "sm_0_7", soilm_lo = 0.10, soilm_hi = 0.25,
    combine = "product",
    window = 28,
    gsi_max = 1.0, greenup = 0.3, persist = 3,
    lhfm_lo = 30, lhfm_hi = 250,
    lwfm_lo = 60, lwfm_hi = 200,
    gate = TRUE
  )
}

# ---- main driver -------------------------------------------------------------

#' Run the GSI Scout model over a daily met series for one point.
#'
#' @param met data.frame with date, doy, tmin_c, vpd_pa, precip_mm, and (if
#'   soil moisture is toggled on) whichever of sm_0_7 / sm_7_28 / sm_28_100
#'   `p$soilm_depth` names.
#' @param lat site latitude, decimal degrees
#' @param p parameter list, see scout_defaults()
#' @return the input augmented with sub-indices, GSI, phase and fuel moistures
run_gsi <- function(met, lat, p = scout_defaults()) {
  d <- met
  d$photo_s <- photoperiod_seconds(d$doy, lat, p$photo_method %||% "geometric")

  d$i_tmin  <- idx_tmin(d$tmin_c, p$tmin_lo, p$tmin_hi)
  d$i_vpd   <- idx_vpd(d$vpd_pa, p$vpd_lo, p$vpd_hi)
  d$i_photo <- idx_photo(d$photo_s, p$photo_lo, p$photo_hi)

  idx <- list(tmin = d$i_tmin, vpd = d$i_vpd, photo = d$i_photo)

  if (isTRUE(p$use_precip)) {
    d$i_precip <- idx_precip(d$precip_mm, p$precip_window, p$precip_lo, p$precip_hi)
    idx$precip <- d$i_precip
  } else {
    d$i_precip <- NA_real_
  }

  if (isTRUE(p$use_soilm)) {
    depth_col <- p$soilm_depth %||% "sm_0_7"
    sm <- met[[depth_col]]
    if (is.null(sm)) stop("run_gsi: met has no column '", depth_col, "'")
    d$i_soilm <- idx_soilm(sm, p$soilm_lo, p$soilm_hi)
    idx$soilm <- d$i_soilm
  } else {
    d$i_soilm <- NA_real_
  }

  d$igsi <- gsi_combine(idx, method = p$combine %||% "product")
  d$gsi  <- gsi_smooth(d$igsi, window = p$window %||% 28)
  d$gsi_rel <- pmin(1, d$gsi / p$gsi_max)

  d$phase <- gsi_phase2(d$gsi_rel, p$greenup, p$persist)

  d$lhfm <- gsi_to_lfm(d$gsi_rel, d$phase, p$lhfm_lo, p$lhfm_hi, p$gate)
  d$lwfm <- gsi_to_lfm(d$gsi_rel, d$phase, p$lwfm_lo, p$lwfm_hi, p$gate)
  d$herb_dead_frac <- herb_load_transfer(d$lhfm)

  # which sub-index is binding on each day
  M <- do.call(cbind, idx)
  colnames(M) <- names(idx)
  bind_levels <- c("tmin", "vpd", "photo", "precip", "soilm")
  d$binding <- factor(colnames(M)[max.col(-M, ties.method = "first")],
                      levels = bind_levels)
  d$binding_value <- M[cbind(seq_len(nrow(M)), max.col(-M, ties.method = "first"))]

  d
}

# ---- season summary ----------------------------------------------------------

#' Key dates and durations a fire manager actually asks about.
gsi_summary <- function(d) {
  first_of <- function(ph) {
    i <- which(d$phase == ph)
    if (length(i)) d$date[i[1]] else as.Date(NA)
  }
  pulses <- greenup_pulses(d$phase)
  list(
    n_pulses      = length(pulses),
    pulse_dates   = d$date[pulses],
    greenup_date  = first_of("greenup"),
    season_length = sum(d$phase == "greenup"),
    peak_gsi      = max(d$gsi, na.rm = TRUE),
    peak_date     = d$date[which.max(d$gsi)],
    min_lhfm      = min(d$lhfm, na.rm = TRUE),
    max_lhfm      = max(d$lhfm, na.rm = TRUE),
    days_full_cure = sum(d$herb_dead_frac >= 0.999, na.rm = TRUE)
  )
}
