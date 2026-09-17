## -----------------------------------------------------------------------------
## plots.R -- every figure GSI Scout draws, as plain functions of data + params.
## Adapted from the Glass Box project's R/plots.R; same house style (plain
## functions, no Shiny knowledge, so they can be rendered outside a session).
##
## Two kinds of figure, matching claude/gsi-pointapp-scope.md's "two layers,
## both first-class" decision:
##   - plot_climate_var() / plot_climatology_panel() -- the selected year's raw
##     driving variables against a 1991-2020 climatology band. Independent of
##     every slider; always answers "was this a weird year" first.
##   - plot_subindex() / plot_gsi() / plot_phase() / plot_lfm() -- the model
##     outputs, which DO respond to the sliders.
## -----------------------------------------------------------------------------

library(ggplot2)
library(patchwork)
## ggiraph powers the "Climatology reference" tab's hover-linked crosshair
## (2026-09-18). Guarded, not a plain library() call: if it's missing this
## whole file must still source cleanly so every OTHER tab keeps working --
## only a call with interactive = TRUE would then fail, with a clear "no
## package called 'ggiraph'" error instead of killing the app at startup.
if (requireNamespace("ggiraph", quietly = TRUE)) library(ggiraph)

if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), ignore.case = TRUE)) {
  for (loc in c("C.UTF-8", "en_US.UTF-8", "C.utf8", "en_US.utf8")) {
    if (nzchar(suppressWarnings(Sys.setlocale("LC_CTYPE", loc)))) break
  }
}

COL <- c(tmin = "#2166AC", vpd = "#B2182B", photo = "#1B7837",
        precip = "#6A3D9A", soilm = "#01665E", soilt = "#B35806")
PHASE_COL <- c(dormant = "#D9D9D9", greenup = "#A6D96A")
GHOST <- "#9E9E9E"
FEMS_COL <- "#E08214"
CLIM_COL <- "#2166AC"   # GSI's own day-of-year climatology band -- reuses
                        # tmin's blue; no clash, the GSI panel has no tmin line

## Sizes bumped +2pt across the board (2026-09-15, at Mike's request -- the
## ramp and GSI model tabs were hard to read) from the original base_size 12 /
## title 10.5 / axis.title.y 9.5 / subtitle 7.3-8.
base_theme <- theme_minimal(base_size = 14) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_line(linewidth = 0.25, colour = "grey88"),
    plot.title = element_text(size = 12.5, face = "bold", margin = margin(b = 3)),
    axis.title.x = element_blank(),
    axis.title.y = element_text(size = 11.5),
    plot.margin = margin(2, 6, 2, 6),
    legend.position = "none"
  )

# ---- climatology reference layer ---------------------------------------------

#' Per-day-of-year summary of a variable across a band of years.
#' @param met a fetch_point() data.frame, with $doy, $year, and `var`
#' @param var column name to summarise
#' @param band_years c(from, to), inclusive; excludes `sel_year` by design so
#'   a single extreme year can't distort its own reference band
#' @return data.frame(doy, lo, mean, hi) -- lo/hi are the 10th/90th percentile
compute_climatology <- function(met, var, band_years, sel_year) {
  ref <- met[met$year >= band_years[1] & met$year <= band_years[2] &
             met$year != sel_year, ]
  agg <- function(f) tapply(ref[[var]], ref$doy, f, na.rm = TRUE)
  data.frame(
    doy  = as.integer(names(agg(mean))),
    lo   = as.numeric(tapply(ref[[var]], ref$doy, quantile, probs = 0.10, na.rm = TRUE)),
    mean = as.numeric(agg(mean)),
    hi   = as.numeric(tapply(ref[[var]], ref$doy, quantile, probs = 0.90, na.rm = TRUE))
  )
}

#' Invisible per-day-of-year hover targets for the ggiraph-linked climatology
#' grid (2026-09-18). One full-height geom_rect_interactive() per row of
#' `sel`, tagged with data_id = doy. Every panel in plot_climatology_panel()
#' is built for the same sel_year, so the same doy is the same calendar day
#' everywhere -- ggiraph highlights matching data_id across every panel in
#' the girafe() object client-side, and with opts_hover(reactive = TRUE) (set
#' where the girafe object is built, in app.R) it also updates
#' input$<outputId>_hovered so a value box can show that day's numbers.
day_hover_rects <- function(sel) {
  ggiraph::geom_rect_interactive(
    data = sel, inherit.aes = FALSE,
    mapping = aes(xmin = doy - 0.5, xmax = doy + 0.5,
                 data_id = as.character(doy),
                 tooltip = format(date, "%b %d, %Y")),
    ymin = -Inf, ymax = Inf, fill = "grey50", alpha = 0.01, colour = NA
  )
}

#' One variable, selected year vs. its climatology band.
#' @param met fetch_point() output (all years)
#' @param var column to plot
#' @param sel_year the focal year
#' @param band_years climatology band, default 1991-2020
#' @param label plot title; units y-axis label
#' @param interactive if TRUE, add ggiraph hover targets (day_hover_rects())
#'   so this panel participates in the climatology tab's linked crosshair --
#'   requires the ggiraph package; see plot_climatology_panel().
plot_climate_var <- function(met, var, sel_year, label, units,
                             band_years = c(1991, 2020), colour = "#333333",
                             interactive = FALSE) {
  clim <- compute_climatology(met, var, band_years, sel_year)
  sel  <- met[met$year == sel_year, c("doy", "date", var)]
  names(sel)[3] <- "value"

  g <- ggplot()
  if (interactive) g <- g + day_hover_rects(sel)
  g <- g +
    geom_ribbon(data = clim, aes(doy, ymin = lo, ymax = hi),
               fill = colour, alpha = 0.15) +
    geom_line(data = clim, aes(doy, mean), colour = colour, alpha = 0.5,
             linewidth = 0.4, linetype = "22") +
    geom_line(data = sel, aes(doy, value), colour = colour, linewidth = 0.7) +
    scale_x_continuous(
      breaks = c(1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335),
      labels = month.abb, expand = c(0.005, 0)) +
    labs(title = label, y = units,
        subtitle = sprintf("%d, shaded = %d-%d 10th-90th pct (year excluded)",
                          sel_year, band_years[1], band_years[2])) +
    base_theme + theme(plot.subtitle = element_text(size = 10, colour = "grey45"))
  g
}

#' Which variables the climatology panel shows, in what order, and how to
#' label/colour them -- one source of truth shared by plot_climatology_panel()
#' (to draw the panels) and app.R's hover value box (to know what to list for
#' a hovered day, in the same order). Soil temperature and soil moisture are
#' each included only if their column made it into `met` (see
#' plot_climatology_panel()'s own note on why that can vary by cache age).
climatology_panel_vars <- function(met, vpd_col, soilm_col = NULL) {
  vars <- list(
    list(var = "daylight_s", label = "Daylength (ERA5)", units = "sec",
        colour = COL[["photo"]]),
    list(var = "tmin_c", label = "Minimum temperature", units = "°C",
        colour = COL[["tmin"]])
  )
  if ("soilt_0_7" %in% names(met)) {
    vars <- c(vars, list(
      list(var = "soilt_0_7", label = "Soil temperature", units = "°C",
          colour = COL[["soilt"]])
    ))
  }
  vars <- c(vars, list(
    list(var = vpd_col, label = "Vapour pressure deficit", units = "Pa",
        colour = COL[["vpd"]]),
    list(var = "precip_mm", label = "Precipitation", units = "mm/day",
        colour = COL[["precip"]])
  ))
  if (!is.null(soilm_col) && soilm_col %in% names(met)) {
    vars <- c(vars, list(
      list(var = soilm_col, label = "Soil moisture", units = "m3/m3",
          colour = COL[["soilm"]])
    ))
  }
  vars
}

#' Per-variable day-of-year climatology (doy, lo, mean, hi), for every
#' variable plot_climatology_panel() shows -- one compute_climatology() call
#' per variable, keyed by column name. 2026-09-19, at Mike's request: this
#' is what lets app.R's hover value box show the climatological mean next to
#' the selected year's value, using the SAME band/exclusion logic as the
#' dashed climatology line each panel already draws (compute_climatology()),
#' so the two can't disagree.
climatology_table_all <- function(met, sel_year, vpd_col, soilm_col = NULL,
                                  band_years = c(1991, 2020)) {
  vars <- climatology_panel_vars(met, vpd_col, soilm_col)
  out <- lapply(vars, function(v) compute_climatology(met, v$var, band_years, sel_year))
  names(out) <- vapply(vars, function(v) v$var, character(1))
  out
}

#' The full climatology reference panel: daylength, minimum temperature,
#' soil temperature, VPD (selected driver), precipitation, and soil moisture
#' -- in that order (2026-09-18, at Mike's request). Independent of the model
#' parameters -- this is the "was this a weird year" view described in
#' claude/gsi-pointapp-scope.md.
#' @param interactive if TRUE, every panel gets ggiraph hover targets and the
#'   result is meant for girafe(), not a plain plotOutput -- see app.R's
#'   "Climatology reference" tab (2026-09-18). Requires the ggiraph package.
plot_climatology_panel <- function(met, sel_year, vpd_col, soilm_col = NULL,
                                   band_years = c(1991, 2020),
                                   interactive = FALSE) {
  vars <- climatology_panel_vars(met, vpd_col, soilm_col)
  panels <- lapply(vars, function(v) {
    plot_climate_var(met, v$var, sel_year, v$label, v$units,
                     band_years, v$colour, interactive = interactive)
  })
  Reduce(`/`, panels)
}

# ---- model outputs -------------------------------------------------------------

#' Sub-indices for the selected year, current parameters. FEMS's seed values
#' are marked with a dashed reference line so the departure from them is
#' visible on the same axis, not just in the slider position.
plot_subindex <- function(d, p) {
  idl <- rbind(
    data.frame(date = d$date, index = "Tmin",        value = d$i_tmin),
    data.frame(date = d$date, index = "VPD",         value = d$i_vpd),
    data.frame(date = d$date, index = "Photoperiod", value = d$i_photo)
  )
  if (isTRUE(p$use_precip))
    idl <- rbind(idl, data.frame(date = d$date, index = "Precipitation", value = d$i_precip))
  if (isTRUE(p$use_soilm))
    idl <- rbind(idl, data.frame(date = d$date, index = "Soil moisture", value = d$i_soilm))

  sub_col <- c(Tmin = COL[["tmin"]], VPD = COL[["vpd"]], Photoperiod = COL[["photo"]],
              Precipitation = COL[["precip"]], `Soil moisture` = COL[["soilm"]])
  idl$index <- factor(idl$index, levels = names(sub_col))

  xs <- scale_x_date(date_labels = "%b", date_breaks = "1 month", expand = c(0.005, 0))
  ggplot(idl, aes(date, value, colour = index)) +
    geom_line(linewidth = 0.7) +
    scale_colour_manual(values = sub_col) +
    scale_y_continuous(limits = c(0, 1)) + xs +
    labs(title = "Sub-indices", y = "index") +
    base_theme + theme(legend.position = "top", legend.title = element_blank())
}

#' GSI, current parameters vs. FEMS defaults (ghost line) and its own
#' day-of-year climatology, with the green-up/dormant threshold marked.
#'
#' The climatology band reuses compute_climatology() -- same function the
#' "Climatology reference" tab runs on the raw driving variables, just called
#' here with `var = "gsi"` on the model's own multi-year output instead. Its
#' `doy` index is projected onto `d`'s year (`clim$date <- Jan 1 of that year
#' + doy - 1`) so it overlays on the same date-based x-axis as everything
#' else in the model stack, rather than switching this one panel to a
#' doy axis the other three panels don't share.
#'
#' @param d run_gsi() output under the current UI parameters
#' @param p params() list
#' @param dd run_gsi() output under scout_defaults() (FEMS seed values), or
#'   NULL to omit the ghost comparison
#' @param clim compute_climatology(gsi_all_years, "gsi", band_years, sel_year)
#'   output (doy, lo, mean, hi), or NULL to omit the climatology band
#' @param band_years the climatology band `clim` was computed over, for the
#'   subtitle label only -- purely cosmetic, doesn't affect what's drawn
plot_gsi <- function(d, p, dd = NULL, clim = NULL, band_years = c(1991, 2020)) {
  xs <- scale_x_date(date_labels = "%b", date_breaks = "1 month", expand = c(0.005, 0))
  sel_year <- as.integer(format(d$date[1], "%Y"))

  g <- ggplot(d, aes(date))

  if (!is.null(clim)) {
    cd <- clim
    cd$date <- as.Date(sprintf("%d-01-01", sel_year)) + cd$doy - 1
    g <- g +
      geom_ribbon(data = cd, aes(x = date, ymin = lo, ymax = hi), inherit.aes = FALSE,
                 fill = CLIM_COL, alpha = 0.15) +
      geom_line(data = cd, aes(x = date, y = mean), inherit.aes = FALSE,
               colour = CLIM_COL, linewidth = 0.5, linetype = "22", alpha = 0.75)
  }

  g <- g + geom_line(aes(y = igsi), colour = "grey72", linewidth = 0.3)
  if (!is.null(dd))
    g <- g + geom_line(data = dd, aes(y = gsi), colour = GHOST, linewidth = 0.7,
                       linetype = "42")

  sub <- if (!is.null(dd))
    "thin grey = daily · dashed = FEMS defaults · black = current"
  else
    "thin grey = daily · black = smoothed"
  sub <- paste0(sub, " · green line = green-up/dormant threshold")
  if (!is.null(clim))
    sub <- paste0(sub, sprintf("\nblue band = %d-%d day-of-year climatology (10th-90th pct, %d excluded)",
                               band_years[1], band_years[2], sel_year))

  g +
    geom_line(aes(y = gsi), colour = "#111111", linewidth = 1.0) +
    geom_hline(yintercept = p$greenup * p$gsi_max, colour = "#A6D96A", linewidth = 0.5) +
    geom_hline(yintercept = p$gsi_max, colour = "grey40", linewidth = 0.4, linetype = "22") +
    scale_y_continuous(limits = c(0, 1)) + xs +
    labs(title = "GSI", y = "GSI", subtitle = sub) +
    base_theme + theme(plot.subtitle = element_text(size = 9.5, colour = "grey45",
                                                     lineheight = 1.05))
}

#' Greenup / dormant phase band.
plot_phase <- function(d) {
  xs <- scale_x_date(date_labels = "%b", date_breaks = "1 month", expand = c(0.005, 0))
  ggplot(d, aes(date, y = 1, fill = phase)) +
    geom_tile(height = 1) +
    scale_fill_manual(values = PHASE_COL, drop = FALSE) + xs +
    labs(title = "Phase", y = NULL) +
    base_theme + theme(axis.text.y = element_blank(), panel.grid = element_blank(),
                       legend.position = "right", legend.title = element_blank())
}

#' Live fuel moisture, herbaceous and woody.
plot_lfm <- function(d) {
  xs <- scale_x_date(date_labels = "%b", date_breaks = "1 month", expand = c(0.005, 0))
  lfml <- rbind(
    data.frame(date = d$date, fuel = "Herbaceous", value = d$lhfm),
    data.frame(date = d$date, fuel = "Woody",      value = d$lwfm)
  )
  ggplot(lfml, aes(date, value, colour = fuel)) +
    geom_line(linewidth = 0.9) +
    geom_hline(yintercept = 120, colour = "grey60", linewidth = 0.3, linetype = "22") +
    scale_colour_manual(values = c(Herbaceous = "#1A9850", Woody = "#8C510A")) +
    xs +
    labs(title = "Live fuel moisture", y = "%",
        subtitle = "dashed 120% = where herbaceous load transfer to 1-h dead begins") +
    base_theme + theme(legend.position = "top", legend.title = element_blank(),
                       plot.subtitle = element_text(size = 9.5, colour = "grey45"))
}

#' The model-output stack: sub-indices, GSI, phase, fuel moisture.
#' @param clim,band_years passed straight through to plot_gsi() -- see there
plot_model_stack <- function(d, p, dd = NULL, clim = NULL, band_years = c(1991, 2020)) {
  (plot_subindex(d, p) / plot_gsi(d, p, dd, clim, band_years) / plot_phase(d) / plot_lfm(d)) +
    plot_layout(heights = c(1.3, 1.8, 0.4, 1.2))
}

# ---- sub-index ramp reference --------------------------------------------------
# The literal shape of each sub-index's gsi_ramp(), across its natural input
# domain, under the current UI parameters -- current sliders (solid) vs.
# FEMS's seed ramp (dashed ghost), the same comparison the GSI model tab
# draws over time, drawn here over the input variable itself instead. Depends
# only on `p` (params() in app.R), not on any fetched data, so this tab
# renders even before "Get data for this point" has ever been clicked.
#
# Depends on gsi.R's gsi_ramp() / scout_defaults() being in scope -- true
# whenever this file is sourced after R/gsi.R, as app.R always does.

#' One sub-index's response curve.
#' @param lo,hi current threshold parameters (raw units, not seconds/fraction
#'   conversions -- callers pass whatever unit the x-axis is in)
#' @param domain numeric vector spanning the x-axis
#' @param decreasing passed to gsi_ramp() -- TRUE for VPD
#' @param fmt function(lo, hi) -> one-line label for the subtitle
#' @param fems_lo,fems_hi FEMS seed values for the ghost line, or NULL to omit
#'   (soil moisture has none -- it isn't a FEMS/NFDRS2016 control)
#' @param active FALSE greys the curve out -- precipitation/soil moisture
#'   when their "Add a ... control" checkbox is off, so the shape previews
#'   before it's turned on rather than disappearing
#' @param note optional second subtitle line, for context that doesn't fit
#'   the fmt() summary (VPD's decreasing direction, photoperiod's convention)
ramp_panel <- function(lo, hi, domain, decreasing, colour, title, x_lab, fmt,
                       fems_lo = NULL, fems_hi = NULL, active = TRUE,
                       note = NULL) {
  cur <- data.frame(x = domain, y = gsi_ramp(domain, lo, hi, decreasing))
  sub <- sprintf("current: %s", fmt(lo, hi))

  g <- ggplot(cur, aes(x, y))
  if (!is.null(fems_lo)) {
    fems <- data.frame(x = domain, y = gsi_ramp(domain, fems_lo, fems_hi, decreasing))
    g <- g + geom_line(data = fems, aes(x, y), colour = FEMS_COL,
                       linewidth = 0.7, linetype = "42")
    sub <- paste0(sub, sprintf("  ·  FEMS: %s", fmt(fems_lo, fems_hi)))
  }
  if (!is.null(note)) sub <- paste0(sub, "\n", note)

  g +
    geom_line(colour = if (active) colour else "grey65",
             linewidth = if (active) 1.0 else 0.8,
             linetype = if (active) "solid" else "22") +
    scale_y_continuous(limits = c(0, 1), breaks = c(0, 0.5, 1)) +
    labs(title = if (active) title else paste(title, "(off)"), x = x_lab, y = "index",
        subtitle = sub) +
    base_theme +
    theme(axis.title.x = element_text(size = 10.5, colour = "grey30"),
         plot.subtitle = element_text(size = 9.3, colour = "grey45", lineheight = 1.05),
         plot.title = element_text(colour = if (active) "black" else "grey55"))
}

## One function per sub-index instead of a single combined grid (2026-09-15,
## at Mike's request) -- each now renders on its own, in its own card, with
## that variable's sliders sitting directly underneath it in app.R, so moving
## a slider updates the plot right there instead of somewhere else on the
## page. Each is still just one ramp_panel() call; only the wiring changed.

#' Minimum temperature ramp.
plot_ramp_tmin <- function(p, show_fems = TRUE) {
  fems <- scout_defaults()
  ramp_panel(
    p$tmin_lo, p$tmin_hi, seq(-15, 25, length.out = 400), FALSE,
    COL[["tmin"]], "Minimum temperature", "Tmin (°C)",
    fmt = function(lo, hi) sprintf("%.1f to %.1f °C", lo, hi),
    fems_lo = if (show_fems) fems$tmin_lo else NULL, fems_hi = fems$tmin_hi)
}

#' Vapour pressure deficit ramp.
plot_ramp_vpd <- function(p, show_fems = TRUE) {
  fems <- scout_defaults()
  ramp_panel(
    p$vpd_lo, p$vpd_hi, seq(0, 9000, length.out = 400), TRUE,
    COL[["vpd"]], "Vapour pressure deficit", "VPD (Pa)",
    fmt = function(lo, hi) sprintf("%.0f to %.0f Pa", lo, hi),
    fems_lo = if (show_fems) fems$vpd_lo else NULL, fems_hi = fems$vpd_hi,
    note = "decreasing: unconstrained left of the low value, fully limiting right of the high value")
}

#' Photoperiod ramp.
plot_ramp_photo <- function(p, show_fems = TRUE) {
  fems <- scout_defaults()
  ramp_panel(
    p$photo_lo / 3600, p$photo_hi / 3600, seq(6, 16, length.out = 400), FALSE,
    COL[["photo"]], "Photoperiod", "daylength (h)",
    fmt = function(lo, hi) sprintf("%.1f to %.1f h", lo, hi),
    fems_lo = if (show_fems) fems$photo_lo / 3600 else NULL, fems_hi = fems$photo_hi / 3600,
    note = sprintf("%s convention -- where the year's actual daylength falls is on Climatology reference",
                  c(geometric = "geometric/FAO-56", sunrise_sunset = "sunrise-to-sunset",
                    civil_twilight = "civil-twilight")[[p$photo_method %||% "geometric"]]))
}

#' Precipitation ramp.
plot_ramp_precip <- function(p, show_fems = TRUE) {
  fems <- scout_defaults()
  ramp_panel(
    p$precip_lo, p$precip_hi, seq(0, 100, length.out = 400), FALSE,
    COL[["precip"]], "Precipitation",
    sprintf("%d-day accumulated total (mm)", p$precip_window %||% 28),
    fmt = function(lo, hi) sprintf("%.1f to %.1f mm", lo, hi),
    fems_lo = if (show_fems) fems$precip_lo else NULL, fems_hi = fems$precip_hi,
    active = isTRUE(p$use_precip))
}

#' Soil moisture ramp.
plot_ramp_soilm <- function(p, show_fems = TRUE) {
  ramp_panel(
    p$soilm_lo, p$soilm_hi, seq(0, 0.6, length.out = 400), FALSE,
    COL[["soilm"]], "Soil moisture", "volumetric water content (m3/m3)",
    fmt = function(lo, hi) sprintf("%.2f to %.2f m3/m3", lo, hi),
    active = isTRUE(p$use_soilm),
    note = "no FEMS reference -- GSI Scout's own addition, not in FEMS or NFDRS2016")
}
