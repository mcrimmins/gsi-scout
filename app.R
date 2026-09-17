## -----------------------------------------------------------------------------
## GSI Scout -- click a point, pick a year, explore the Growing Season Index.
##
## Companion to the Glass Box app (GrowingSeasonIndex project): where Glass Box
## is a config-driven two-site comparison tool for internal tuning sessions,
## GSI Scout is public-facing and single-point -- any location, live ERA5 via
## Open-Meteo, no site catalog. See claude/gsi-pointapp-scope.md (Claude
## project "Growing Season Index for Wildland Fire") for the full scoping
## conversation this app was built from.
##
## Run:  Rscript -e 'shiny::runApp(".", port = 7777)'
## Deploy: Rscript deploy.R  (see that file -- do not use RStudio's Republish
##         button; see its header for why)
## -----------------------------------------------------------------------------

library(shiny)
library(bslib)
library(leaflet)
## Guarded like R/plots.R's own ggiraph line -- see that file's comment.
## girafeOutput/renderGirafe/girafe() are only reachable if this succeeds;
## the "Climatology reference" tab is the one place that needs them.
if (requireNamespace("ggiraph", quietly = TRUE)) library(ggiraph)

source("R/gsi.R")
source("R/fetch.R")
source("R/plots.R")

DEF <- scout_defaults()
YEARS <- 1991:2025
CLIMATOLOGY_BAND <- c(1991, 2020)

## The app's starting point (Tucson) doubles as an offline test point: run
## data-raw/make_sample_cache.R once and every year 1991-2025 at this exact
## lat/lon is a synthetic-but-realistic cache hit, so UI/layout iteration
## never has to touch Open-Meteo. See that script's header before trusting
## any number that comes out of it for anything but layout.
TEST_LAT <- 32.22
TEST_LON <- -110.93

# ---- UI ------------------------------------------------------------------------

fems_note <- function(txt) helpText(HTML(sprintf(
  "<span style='color:#E08214;font-weight:600;'>FEMS default</span>: %s", txt)))

param_accordion <- accordion(
  open = c("Location & year"),

  accordion_panel(
    "Location & year", icon = NULL,
    p("Click the map to choose a point."),
    verbatimTextOutput("point_label"),
    selectInput("sel_year", "Year", choices = rev(YEARS), selected = max(YEARS)),
    actionButton("fetch", "Get data for this point", class = "btn-primary w-100"),
    checkboxInput("force_refresh", "Ignore cache, re-fetch from Open-Meteo", FALSE),
    helpText("Pulls historical weather for this point, from 1991 through the
             selected year. Once fetched, revisiting the same point or
             changing its year loads instantly. If the results look off for a
             point you've used before, check “ignore cache” to force a fresh
             fetch.")
  ),

  ## The per-variable threshold sliders (Tmin, VPD, photoperiod, precip,
  ## soil moisture) used to live in three panels here. Moved to sit directly
  ## under each variable's plot on the "Sub-index ramps" tab instead
  ## (2026-09-15, at Mike's request) -- same input IDs, so params() and the
  ## reset-to-FEMS logic below didn't need to change, only their location in
  ## the page. See claude/gsi-pointapp-scope.md.

  accordion_panel(
    "Phase & scaling",
    checkboxInput("show_fems_ghost", "Show FEMS defaults for comparison (dashed)",
                  TRUE),
    helpText("Draws the GSI curve under FEMS's seed values as a dashed ghost",
            "line on the GSI model and Sub-index ramps tabs, alongside your",
            "current sliders."),
    tags$hr(),
    sliderInput("gsi_max", "GSImax (site calibration)", 0.2, 1.0, DEF$gsi_max, 0.01),
    fems_note(sprintf("%.0f", DEF$gsi_max)),
    sliderInput("greenup", "green-up / dormant threshold (relative GSI)", 0, 1,
                DEF$greenup, 0.01),
    fems_note(sprintf("%.1f", DEF$greenup)),
    sliderInput("persist", "days above/below threshold to switch phase", 1, 21,
                DEF$persist, 1),
    sliderInput("window", "GSI running average length (days)", 1, 60,
                DEF$window, 1),
    fems_note(sprintf("%d days", DEF$window)),
    helpText("A site is always in one of two states, green-up or dormant. A dry
             spell can push it back to dormant at any time during the season --
             it doesn't have to wind down through another stage first."),
    tags$hr(),
    tags$b("Live fuel moisture endpoints (%)"),
    sliderInput("lhfm_lo", "herbaceous, at dormant", 0, 100, DEF$lhfm_lo, 1),
    sliderInput("lhfm_hi", "herbaceous, at GSImax", 100, 300, DEF$lhfm_hi, 1),
    fems_note(sprintf("herbaceous %d-%d%%", DEF$lhfm_lo, DEF$lhfm_hi)),
    sliderInput("lwfm_lo", "woody, at dormant", 0, 100, DEF$lwfm_lo, 1),
    sliderInput("lwfm_hi", "woody, at GSImax", 100, 250, DEF$lwfm_hi, 1),
    fems_note(sprintf("woody %d-%d%%", DEF$lwfm_lo, DEF$lwfm_hi)),
    sliderInput("gu_herb", "herbaceous green-up threshold GU", 0, 0.9, DEF$gu_herb, 0.05),
    sliderInput("gu_woody", "woody green-up threshold GU", 0, 0.9, DEF$gu_woody, 0.05),
    helpText(HTML("Moisture ramps from its minimum at <b>GU</b> to its maximum
                   at GSImax (Jolly et al. 2024, Eq. 10) &mdash; not from zero.
                   FEMS does not list this one. The paper's default is
                   <b>0.2</b>; NWCG PMS 437 describes <b>0.5</b>; FEMS's own
                   green-up threshold above is 0.3. Setting GU to 0 restores the
                   plain proportional mapping."))
  ),

  accordion_panel(
    "Reset",
    actionButton("reset_fems", "Reset all sliders to FEMS defaults",
                class = "btn-outline-secondary w-100")
  ),

  ## Closed by default (only "Location & year" is in accordion()'s `open`
  ## list above) so a real user clicking through the sidebar doesn't land on
  ## this by accident (2026-09-15, at Mike's request) -- it used to sit right
  ## in "Location & year", one click away from "Get data for this point."
  accordion_panel(
    "Developer / testing",
    actionButton("use_test_point", "Use offline test point (no network)",
                class = "btn-outline-secondary w-100"),
    helpText(HTML("Snaps to Tucson and loads instantly from a bundled
                  <b>synthetic</b> cache covering every year -- for UI/layout
                  work only, never for a real read on GSI. Run
                  <code>Rscript data-raw/make_sample_cache.R</code> once to
                  (re)generate it if <code>data/cache/</code> doesn't have
                  it yet."))
  )
)

## Three full-width tabs instead of two squeezed side-by-side cards -- each
## panel (map, climatology reference, model stack) gets the whole content
## width rather than sharing it, which is what the stacked ggplot/patchwork
## figures need to be legible. "Map & point" is listed first so Leaflet
## initialises while its tab is visible (a hidden/zero-width container at
## init is a known source of broken Leaflet renders).
main_tabs <- navset_card_tab(
  id = "main_tabs",

  nav_panel(
    "Map & point",
    p("Click the map to choose a point, then use \"Get data for this point\"",
      "in the sidebar. Base layer switcher is in the top-right of the map."),
    ## Dashed box (2026-09-18, at Mike's request): the ERA5 grid box
    ## bracketing the pin -- NOT a "your point lives in this cell" box.
    ## Open-Meteo interpolates between the four native ERA5 grid points at
    ## this box's corners, ~28 km apart -- worth seeing at a glance, since
    ## it's easy to forget a single clicked point is standing in for that
    ## whole area.
    helpText(HTML(
      "Dashed box: the ERA5 grid cell (0.25°, ~28 km) bracketing the pin --",
      "Open-Meteo interpolates weather between its four corners, not a",
      "point measurement at the pin itself."
    )),
    leafletOutput("map", height = 640)
  ),

  ## Second, not first -- "Map & point" stays the default active tab so
  ## Leaflet initialises while it's visible (see that nav_panel's own
  ## comment). Still one click away from the map for a brand-new user.
  nav_panel(
    "How to use",
    tags$h5("Getting started"),
    tags$ol(
      tags$li("Click anywhere on the map (the \"Map & point\" tab) to pick a",
              "location. The pin moves there."),
      tags$li("Pick a year from the \"Year\" dropdown in the sidebar",
              "(1991-2025)."),
      tags$li("Click \"Get data for this point.\" The first fetch for a new",
              "location takes a little while; after that, revisiting the",
              "same point or changing its year is instant.")
    ),
    tags$h5("Then explore"),
    tags$ul(
      tags$li(strong("Climatology reference"), " -- was this a normal year",
              "or an unusual one, before any modeling is applied."),
      tags$li(strong("Sub-index ramps"), " -- the GSI curve (with its own",
              "climatology) up top, then what each slider actually does,",
              "compared against the standard default."),
      tags$li(strong("GSI model"), " -- the full picture: green-up/dormancy",
              "timing, live fuel moisture, and the index itself.")
    ),
    tags$h5("Adjusting the model"),
    p("Each threshold lives right under its plot on the \"Sub-index",
      "ramps\" tab, starting at the standard (\"FEMS\") default value shown",
      "in that plot's subtitle. Move a slider there to see the curve",
      "change immediately, then switch to \"GSI model\" to see what it did",
      "to the full year. \"Reset all sliders to FEMS defaults,\" at the",
      "bottom of the sidebar, snaps every one of them back at once."),
    p("Precipitation and soil moisture are off by default -- their cards",
      "on the \"Sub-index ramps\" tab each have their own checkbox to add",
      "them to the model and see their effect."),
    tags$h5("Tips"),
    tags$ul(
      tags$li("The map's layer switcher (top-right of the map) swaps",
              "between topographic and satellite views."),
      tags$li("\"Show FEMS defaults for comparison,\" in the sidebar's",
              "\"Phase & scaling\" section, draws a dashed reference line",
              "on both the GSI model and Sub-index ramps tabs, so you can",
              "always see how far you've moved from the standard.")
    )
  ),

  nav_panel(
    "Climatology reference",
    p("The selected year against its 1991-2020 climatology band --",
      "independent of every slider, so this always answers",
      "“was this a weird year” first. Hover any panel to line up that",
      "day across all six and see its values at right."),
    ## 1800px, not 1500 -- soil temperature joined soil moisture as a normal
    ## (usually-shown) panel 2026-09-18, so this is typically 6 stacked
    ## panels now instead of 5. Two columns (2026-09-18): the ggiraph plot
    ## at left, a sticky hover value box at right -- see
    ## output$climatology_plot / output$climatology_hover_box below.
    ##
    ## Two bslib gotchas found by inspecting the live DOM (a plain static-
    ## HTML reproduction in dev didn't catch either -- bslib's JS fill/height
    ## engine never ran there):
    ##   1. layout_columns()'s grid measured its own row height at ~650px
    ##      instead of the girafe widget's real ~1800px (it likely sizes
    ##      before ggiraph's async JS resize), so the sticky box's own
    ##      containing block ended 1150px too early and it "fell off" past
    ##      that point. height = "1800px" below pins the row explicitly
    ##      instead of trusting that measurement.
    ##   2. fillable/fill = TRUE (the default) makes this grid and its
    ##      children "fill" items that bslib's JS shrinks to whatever space
    ##      it thinks is available -- it was collapsing the value-card to
    ##      ~140px tall with its own internal scrollbar, hiding most of its
    ##      rows. fillable = FALSE, fill = FALSE opts both columns out of
    ##      that system so they just take their natural/declared size.
    layout_columns(
      col_widths = c(9, 3), height = "1800px", fillable = FALSE, fill = FALSE,
      girafeOutput("climatology_plot", height = "1800px"),
      ## Plain markup, not card()/card_header() -- bslib's card() carries
      ## its own overflow:auto + fill-height CSS (independent of the grid
      ## settings above), which was the other half of gotcha #2.
      div(
        style = paste(
          "position: sticky; top: 12px; align-self: start;",
          "border: 1px solid #dee2e6; border-radius: 0.375rem;",
          "background-color: #fff;"
        ),
        div(style = "font-weight: 600; padding: 0.5rem 1rem; border-bottom: 1px solid #dee2e6;",
            "Day"),
        div(style = "padding: 0.75rem 1rem;",
            uiOutput("climatology_hover_box"))
      )
    )
  ),

  nav_panel(
    "Sub-index ramps",
    p("The GSI curve for the selected point/year sits above, so you can see",
      "what these ramps actually produce while adjusting them. Below: what",
      "each slider does -- index value (0-1) across the raw variable's",
      "full range, current settings vs. FEMS's seed ramp (dashed). The",
      "ramp cards need no data, so they don't require \"Get data for this",
      "point\" first; precipitation and soil moisture show their shape",
      "even while their control is off. Adjust the sliders under each plot",
      "directly -- they're the same controls that feed the GSI model tab,",
      "just relocated here, next to what they do."),

    ## Same card(fill = FALSE) fix as every ramp card below -- without it,
    ## bslib collapses this card's height before the plot has any room to
    ## draw, which is exactly the "figure margins too large" error (see the
    ## comment on the ramp grid just below; same cause, same fix, just missed
    ## here the first time).
    card(
      fill = FALSE,
      uiOutput("ramp_gsi_hint"),
      plotOutput("ramp_gsi_plot", height = 300)
    ),
    tags$hr(),

    ## layout_column_wrap(width = 1/3), not a fixed 2-column layout_columns()
    ## -- 5 cards in 2 columns leaves the 5th (soil moisture) alone on its own
    ## row, half-empty. 3 columns packs them 3-then-2, and wraps down to fewer
    ## columns on a narrower window on its own (2026-09-17, at Mike's request
    ## -- the ramps tab plus the GSI plot above it didn't fit without a lot of
    ## scrolling). Ramp plot heights trimmed 420 -> 320 for the same reason;
    ## still readable, just not as tall. Each card keeps fill = FALSE -- see
    ## the comment above for why that matters.
    layout_column_wrap(
      width = 1/3, fill = FALSE, heights_equal = "row",

      card(
        fill = FALSE,
        plotOutput("ramp_tmin", height = 320),
        tags$b("Minimum temperature (°C)"),
        sliderInput("tmin_range", "limiting → unconstrained", -15, 25,
                    c(DEF$tmin_lo, DEF$tmin_hi), 0.5),
        fems_note(sprintf("%.1f to %.1f °C", DEF$tmin_lo, DEF$tmin_hi))
      ),

      card(
        fill = FALSE,
        plotOutput("ramp_vpd", height = 320),
        tags$b("Vapour pressure deficit (Pa)"),
        sliderInput("vpd_range", "unconstrained → limiting", 0, 9000,
                    c(DEF$vpd_lo, DEF$vpd_hi), 25),
        selectInput("vpd_driver", "which VPD drives the model",
                    c("ERA5 hourly max (FEMS: \"VPD max\")" = "native_max",
                      "ERA5 hourly mean" = "native_mean",
                      "FAO-56 from Tmax/Tmin/dewpoint (Jolly 2005)" = "fao56"),
                    selected = DEF$vpd_driver),
        fems_note(sprintf("%d to %d Pa, VPD max", DEF$vpd_lo, DEF$vpd_hi))
      ),

      card(
        fill = FALSE,
        plotOutput("ramp_photo", height = 320),
        tags$b("Daylength (hours)"),
        sliderInput("photo_range", "limiting → unconstrained", 6, 16,
                    c(DEF$photo_lo / 3600, DEF$photo_hi / 3600), 0.1),
        selectInput("photo_method", "daylength convention",
                    c("Geometric / FAO-56 (Jolly 2005, Daham 2018)" = "geometric",
                      "Sunrise to sunset (+refraction)" = "sunrise_sunset",
                      "Civil twilight" = "civil_twilight"),
                    selected = DEF$photo_method),
        fems_note(sprintf("%.0f to %.0f h", DEF$photo_lo / 3600, DEF$photo_hi / 3600)),
        helpText(HTML("Geometric daylength never reaches 11 h in the desert
                       Southwest in winter, so this ramp will likely need
                       adjusting down from the FEMS seed for southwestern
                       sites -- that gap is the point, not a bug."))
      ),

      card(
        fill = FALSE,
        plotOutput("ramp_precip", height = 320),
        checkboxInput("use_precip", "Add a precipitation control", DEF$use_precip),
        conditionalPanel("input.use_precip",
          sliderInput("precip_window", "accumulation window (days)", 1, 90,
                      DEF$precip_window, 1),
          sliderInput("precip_range", "limiting → unconstrained (mm accumulated)",
                      0, 100, c(DEF$precip_lo, DEF$precip_hi), 0.5),
          fems_note(sprintf("28-day window, 0.4-0.8 in (%.1f-%.1f mm)",
                            DEF$precip_lo, DEF$precip_hi))
        )
      ),

      card(
        fill = FALSE,
        plotOutput("ramp_soilm", height = 320),
        helpText("Not part of FEMS or NFDRS2016 -- GSI Scout's own addition, an
                 open question rather than an established control. Which depth
                 suits herbaceous vs. woody fuels is exactly what this control
                 is for exploring."),
        checkboxInput("use_soilm", "Add a soil moisture control", DEF$use_soilm),
        conditionalPanel("input.use_soilm",
          selectInput("soilm_depth", "depth",
                      c("0-7 cm" = "sm_0_7", "7-28 cm" = "sm_7_28",
                        "28-100 cm" = "sm_28_100"), selected = DEF$soilm_depth),
          sliderInput("soilm_range", "limiting → unconstrained (m3/m3)",
                      0, 0.6, c(DEF$soilm_lo, DEF$soilm_hi), 0.01)
        )
      )
    )
  ),

  nav_panel(
    "GSI model",
    uiOutput("model_status"),
    ## The four summary-stat value_box cards (pulses, first green-up, days in
    ## green-up, peak GSI) that used to sit here -- first beside the plot,
    ## then below it, then as an inset table on the GSI panel -- were removed
    ## entirely (2026-09-15, at Mike's request: "clean plot and no stats on
    ## this page"). Just the plot now.
    plotOutput("model_plot", height = 2400)
  )
)

ui <- page_sidebar(
  title = "GSI Scout -- Growing Season Index Calculator",
  theme = bs_theme(version = 5),
  sidebar = sidebar(width = 380, param_accordion),
  main_tabs
)

# ---- server ----------------------------------------------------------------------

server <- function(input, output, session) {

  pt <- reactiveValues(lat = 32.22, lon = -110.93)  # Tucson, as a starting point
  met <- reactiveVal(NULL)
  status <- reactiveVal("Click the map, then \"Get data for this point\".")

  # Selection marker + its bracketing ERA5 grid box (2026-09-18), on `map` --
  # a leaflet map widget (initial render) or a leafletProxy (the two
  # point-setting observers below). One function so the three call sites
  # can't drift out of sync with each other. interactive = FALSE on the
  # rectangle so its border can't swallow a map click meant to move the pin.
  draw_point <- function(map, lat, lon) {
    gb <- era5_grid_box(lat, lon)
    map |>
      addRectangles(lng1 = gb$lon0, lat1 = gb$lat0, lng2 = gb$lon1, lat2 = gb$lat1,
                    layerId = "era5_grid", fill = FALSE,
                    color = "#444444", weight = 1.5, dashArray = "4,3",
                    options = pathOptions(interactive = FALSE)) |>
      addMarkers(lng = lon, lat = lat, layerId = "sel")
  }

  ## isolate() around the whole body is load-bearing, not decoration:
  ## without it, reading pt$lat/pt$lon below makes this ENTIRE block re-run
  ## on every pt change (i.e. every map click), tearing down and rebuilding
  ## the whole widget at zoom 5 -- wiping out whatever pan/zoom the user had
  ## and undoing the leafletProxy() updates the click observers just made a
  ## moment earlier. Those observers are the only thing that should move the
  ## view after this initial render; this block just needs pt's value once,
  ## at startup.
  output$map <- renderLeaflet({
    isolate({
      # No API key needed for any of these. USGS Topo is the default: it's the
      # standard US topographic product land management agencies already use,
      # and (unlike CartoDB.Positron, which now gates its tiles behind an API
      # key -- see the "API KEY REQUIRED" watermark that prompted this change)
      # it bakes in terrain shading, roads, towns, and often land-unit
      # boundaries (national forests, wilderness areas) as part of the base
      # map itself. Esri's topo and imagery layers are offered as alternates
      # via the layer switcher (top right of the map) -- global coverage,
      # where USGS Topo is US/territories only.
      leaflet() |>
        addTiles(
          urlTemplate = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
          attribution = "USGS The National Map",
          group = "USGS Topo (land units, terrain, roads)"
        ) |>
        addProviderTiles(providers$Esri.WorldTopoMap, group = "Esri Topo") |>
        addProviderTiles(providers$Esri.WorldImagery, group = "Esri Imagery") |>
        addLayersControl(
          baseGroups = c("USGS Topo (land units, terrain, roads)",
                         "Esri Topo", "Esri Imagery"),
          options = layersControlOptions(collapsed = FALSE)
        ) |>
        setView(lng = pt$lon, lat = pt$lat, zoom = 5) |>
        draw_point(pt$lat, pt$lon)
    })
  })

  observeEvent(input$map_click, {
    pt$lat <- input$map_click$lat
    pt$lon <- input$map_click$lng
    leafletProxy("map") |>
      clearMarkers() |>
      clearShapes() |>
      draw_point(pt$lat, pt$lon)
    status(sprintf("Point set to %.3f, %.3f. Click \"Get data for this point\".",
                   pt$lat, pt$lon))
  })

  output$point_label <- renderText({
    sprintf("lat %.3f, lon %.3f", pt$lat, pt$lon)
  })

  # Shared by both "Get data for this point" and "Use offline test point" --
  # same fetch_point() call either way, since the test point is just a cache
  # entry at a known lat/lon rather than a separate code path. A real point
  # with no cache yet hits the network; the test point never does (see
  # data-raw/make_sample_cache.R).
  do_fetch <- function(lat, lon) {
    withProgress(message = "Fetching Open-Meteo data", value = 0.2, {
      d <- tryCatch(
        fetch_point(lat, lon, year_to = as.integer(input$sel_year),
                   year_from = CLIMATOLOGY_BAND[1],
                   refresh = isTRUE(input$force_refresh),
                   progress = function(m) incProgress(0.1, detail = m)),
        error = function(e) { status(paste("Fetch failed:", conditionMessage(e))); NULL }
      )
      if (!is.null(d)) {
        met(d)
        status(sprintf("Loaded %s days for %.3f, %.3f.",
                       format(nrow(d), big.mark = ","), lat, lon))
      }
    })
  }

  observeEvent(input$fetch, {
    do_fetch(pt$lat, pt$lon)
  })

  observeEvent(input$use_test_point, {
    pt$lat <- TEST_LAT
    pt$lon <- TEST_LON
    leafletProxy("map") |>
      clearMarkers() |>
      clearShapes() |>
      setView(lng = pt$lon, lat = pt$lat, zoom = 8) |>
      draw_point(pt$lat, pt$lon)
    do_fetch(TEST_LAT, TEST_LON)
  })

  observeEvent(input$reset_fems, {
    d <- scout_defaults()
    updateSliderInput(session, "tmin_range", value = c(d$tmin_lo, d$tmin_hi))
    updateSliderInput(session, "vpd_range", value = c(d$vpd_lo, d$vpd_hi))
    updateSelectInput(session, "vpd_driver", selected = d$vpd_driver)
    updateSliderInput(session, "photo_range",
                      value = c(d$photo_lo / 3600, d$photo_hi / 3600))
    updateSelectInput(session, "photo_method", selected = d$photo_method)
    updateCheckboxInput(session, "use_precip", value = d$use_precip)
    updateSliderInput(session, "precip_window", value = d$precip_window)
    updateSliderInput(session, "precip_range", value = c(d$precip_lo, d$precip_hi))
    updateCheckboxInput(session, "use_soilm", value = d$use_soilm)
    updateSelectInput(session, "soilm_depth", selected = d$soilm_depth)
    updateSliderInput(session, "soilm_range", value = c(d$soilm_lo, d$soilm_hi))
    updateSliderInput(session, "gsi_max", value = d$gsi_max)
    updateSliderInput(session, "greenup", value = d$greenup)
    updateSliderInput(session, "persist", value = d$persist)
    updateSliderInput(session, "window", value = d$window)
    updateSliderInput(session, "lhfm_lo", value = d$lhfm_lo)
    updateSliderInput(session, "lhfm_hi", value = d$lhfm_hi)
    updateSliderInput(session, "lwfm_lo", value = d$lwfm_lo)
    updateSliderInput(session, "lwfm_hi", value = d$lwfm_hi)
    updateSliderInput(session, "gu_herb", value = d$gu_herb)
    updateSliderInput(session, "gu_woody", value = d$gu_woody)
  })

  # current parameter list, built from the UI every time an input changes
  params <- reactive({
    ## Each *_range input is a two-handle slider (value = c(lo, hi)) instead
    ## of a separate pair of sliders -- "one slider that sets the range"
    ## (2026-09-15). req() guards each: a range slider's value briefly comes
    ## through as a single number during Shiny's client/server handshake on
    ## first load, and indexing [2] on that would error.
    req(length(input$tmin_range) == 2, length(input$vpd_range) == 2,
       length(input$photo_range) == 2, length(input$precip_range) == 2,
       length(input$soilm_range) == 2)
    list(
      tmin_lo = input$tmin_range[1], tmin_hi = input$tmin_range[2],
      vpd_lo = input$vpd_range[1], vpd_hi = input$vpd_range[2],
      vpd_driver = input$vpd_driver,
      photo_lo = input$photo_range[1] * 3600, photo_hi = input$photo_range[2] * 3600,
      photo_method = input$photo_method,
      use_precip = input$use_precip, precip_window = input$precip_window,
      precip_lo = input$precip_range[1], precip_hi = input$precip_range[2],
      use_soilm = input$use_soilm, soilm_depth = input$soilm_depth,
      soilm_lo = input$soilm_range[1], soilm_hi = input$soilm_range[2],
      combine = "product", window = input$window,
      gsi_max = input$gsi_max, greenup = input$greenup, persist = input$persist,
      lhfm_lo = input$lhfm_lo, lhfm_hi = input$lhfm_hi,
      lwfm_lo = input$lwfm_lo, lwfm_hi = input$lwfm_hi,
      gu_herb = input$gu_herb %||% 0.2, gu_woody = input$gu_woody %||% 0.2,
      gate = TRUE
    )
  })

  met_year <- reactive({
    req(met())
    m <- met()
    p <- params()
    m$vpd_pa <- m[[vpd_driver_col(p$vpd_driver)]]
    m
  })

  gsi_all_years <- reactive({
    req(met_year())
    run_gsi(met_year(), pt$lat, params())
  })

  gsi_sel <- reactive({
    req(gsi_all_years())
    d <- gsi_all_years()
    d[d$year == as.integer(input$sel_year), ]
  })

  gsi_fems <- reactive({
    req(met_year(), input$show_fems_ghost)
    d <- met_year()
    dd <- run_gsi(d, pt$lat, scout_defaults())
    dd[dd$year == as.integer(input$sel_year), ]
  })

  # Day-of-year GSI climatology, current sliders -- same compute_climatology()
  # the "Climatology reference" tab runs on the raw driving variables, called
  # here on the model's own multi-year gsi_all_years() output instead. Shared
  # by both places plot_gsi() now appears (this tab and "GSI model") so they
  # stay in sync rather than each computing it separately.
  gsi_climatology <- reactive({
    req(gsi_all_years())
    compute_climatology(gsi_all_years(), "gsi", CLIMATOLOGY_BAND,
                        as.integer(input$sel_year))
  })

  # Per-variable day-of-year climatology for the Climatology reference tab's
  # hover box (2026-09-19) -- same vars/band/exclusion as the dashed
  # climatology line each panel already draws, computed once here rather
  # than per-hover-event in the (frequently-firing) hover box below.
  climatology_tables <- reactive({
    req(met())
    climatology_table_all(met_year(), as.integer(input$sel_year),
                          vpd_col = vpd_driver_col(input$vpd_driver),
                          soilm_col = input$soilm_depth %||% "sm_0_7",
                          band_years = CLIMATOLOGY_BAND)
  })

  output$climatology_plot <- renderGirafe({
    req(met())
    m <- met_year()
    # Soil moisture's climatology shows regardless of the "add a soil
    # moisture control" toggle -- this panel is meant to be independent of
    # every slider (see the tab's own description text), and the depth
    # selector still has a value even while its conditionalPanel is hidden,
    # so there's no reason to gate the plot on the toggle too.
    p <- plot_climatology_panel(m, as.integer(input$sel_year),
                                vpd_col = vpd_driver_col(input$vpd_driver),
                                soilm_col = input$soilm_depth %||% "sm_0_7",
                                band_years = CLIMATOLOGY_BAND,
                                interactive = TRUE)
    # reactive = TRUE also drives input$climatology_plot_hovered (the
    # data_id, i.e. day-of-year as a string) for the value box below; the
    # CSS is the purely client-side highlight, linked across all 6 panels
    # by day_hover_rects()'s shared data_id (see R/plots.R).
    girafe(ggobj = p, width_svg = 9, height_svg = 17,
          options = list(
            opts_hover(css = "fill:#2166AC;fill-opacity:0.15;", reactive = TRUE),
            opts_tooltip(opacity = 0.9),
            opts_sizing(rescale = TRUE)
          ))
  })

  # Values for whichever day is currently hovered on the climatology grid --
  # same variable list/order/colour as the plot itself (climatology_panel_vars(),
  # R/plots.R), so this box and the panels never drift out of sync. Also
  # shows the day-of-year climatological mean (2026-09-19, at Mike's
  # request) next to the selected year's value, from climatology_tables()
  # above -- the same numbers behind each panel's own dashed climatology
  # line, so this box and the plot always agree.
  fmt_val <- function(x, units) {
    if (is.null(x) || length(x) == 0 || is.na(x)) return("--")
    sprintf("%s %s", format(round(x, 2)), units)
  }

  output$climatology_hover_box <- renderUI({
    req(met())
    hov <- input$climatology_plot_hovered
    if (is.null(hov) || !nzchar(hov)) {
      return(helpText("Hover any panel to see that day's values here."))
    }
    # met_year() is every fetched year, not just the selected one (its own
    # comment/name is about adding vpd_pa, not about filtering) -- doy alone
    # repeats every year, so this must also pin the year or it silently
    # picks up whichever year happens to sort first (1991, the earliest).
    m <- met_year()
    hov_doy <- as.integer(hov)
    row <- m[m$doy == hov_doy & m$year == as.integer(input$sel_year), ]
    if (nrow(row) == 0) return(helpText("Hover any panel to see that day's values here."))
    row <- row[1, ]
    vars <- climatology_panel_vars(m, vpd_col = vpd_driver_col(input$vpd_driver),
                                   soilm_col = input$soilm_depth %||% "sm_0_7")
    clim <- climatology_tables()
    tagList(
      tags$strong(format(row$date, "%B %d, %Y")),
      tags$table(class = "table table-sm", style = "margin-top: 6px;",
        tags$thead(
          tags$tr(
            tags$th(""),
            tags$th(style = "text-align:right;", as.character(input$sel_year)),
            tags$th(style = "text-align:right; font-weight:400; color:grey;",
                    sprintf("%d-%d avg", CLIMATOLOGY_BAND[1], CLIMATOLOGY_BAND[2]))
          )
        ),
        tags$tbody(
          lapply(vars, function(v) {
            val <- row[[v$var]]
            ct <- clim[[v$var]]
            clim_mean <- if (is.null(ct)) NA_real_ else ct$mean[ct$doy == hov_doy]
            tags$tr(
              tags$td(style = sprintf("color:%s; font-weight:600; padding-right: 8px;", v$colour),
                      v$label),
              tags$td(style = "text-align:right; white-space:nowrap;",
                      fmt_val(val, v$units)),
              tags$td(style = "text-align:right; white-space:nowrap; color:grey;",
                      fmt_val(clim_mean, v$units))
            )
          })
        )
      )
    )
  })

  # Pure functions of the sliders (params()) -- no req(met()) needed, unlike
  # every other plot in this app. Five separate outputs, one per card, since
  # each slider now sits directly under its own plot rather than one combined
  # image. See the plot_ramp_*() functions' header in R/plots.R.
  output$ramp_tmin <- renderPlot({
    plot_ramp_tmin(params(), show_fems = isTRUE(input$show_fems_ghost))
  })
  output$ramp_vpd <- renderPlot({
    plot_ramp_vpd(params(), show_fems = isTRUE(input$show_fems_ghost))
  })
  output$ramp_photo <- renderPlot({
    plot_ramp_photo(params(), show_fems = isTRUE(input$show_fems_ghost))
  })
  output$ramp_precip <- renderPlot({
    plot_ramp_precip(params(), show_fems = isTRUE(input$show_fems_ghost))
  })
  output$ramp_soilm <- renderPlot({
    plot_ramp_soilm(params(), show_fems = isTRUE(input$show_fems_ghost))
  })

  output$model_plot <- renderPlot({
    req(gsi_sel())
    dd <- if (isTRUE(input$show_fems_ghost)) gsi_fems() else NULL
    plot_model_stack(gsi_sel(), params(), dd, gsi_climatology(), CLIMATOLOGY_BAND)
  })

  # GSI plot repeated on "Sub-index ramps", above the ramp cards -- same
  # underlying plot_gsi() call as the "GSI model" tab's own GSI panel, kept
  # in sync automatically since both read from the same reactives. Unlike
  # the ramp cards below it, this one needs fetched data, so a hint stands
  # in for it until "Get data for this point" has been clicked.
  output$ramp_gsi_hint <- renderUI({
    if (is.null(met())) {
      p(class = "text-muted small mb-2",
        "Click the map, then “Get data for this point,” to see the GSI curve here.")
    }
  })

  output$ramp_gsi_plot <- renderPlot({
    req(gsi_sel())
    dd <- if (isTRUE(input$show_fems_ghost)) gsi_fems() else NULL
    plot_gsi(gsi_sel(), params(), dd, gsi_climatology(), CLIMATOLOGY_BAND)
  })

  output$model_status <- renderUI({
    p(class = "text-muted small mb-2", status())
  })
}

shinyApp(ui, server)
