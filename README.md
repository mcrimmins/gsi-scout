# GSI Scout

Click a point on a map, pick a year, and explore the Growing Season Index
(GSI) for that location -- driving weather from ERA5 via Open-Meteo, every
FEMS operational default exposed as a live, adjustable control.

Built for Cheryl (a land manager) and scoped from a conversation with her
(`convo_on_gsi.docx`) before any code was written. The full scoping
conversation lives in the Claude project "Growing Season Index for Wildland
Fire," doc `claude/gsi-pointapp-scope.md`.

## How this differs from Glass Box

This project's sibling, `GrowingSeasonIndex` (the "Glass Box" app), is a
config-driven, two-site comparison tool for internal tuning sessions, seeded
on NFDRS2016's literature defaults. GSI Scout is public-facing and
single-point -- any location, no site catalog -- and seeded on FEMS's
*operational* parameter values instead, which are not the same numbers
(e.g. VPD 1956-3882 Pa here vs. NFDRS2016's 900-4100 Pa in Glass Box). GSI
Scout also uses a simpler 2-phase (green-up / dormant) model rather than
Glass Box's 5-state greenup/maintenance/senescence/cured machine, so that
drought can push a site back to dormancy at any point rather than requiring
it to pass through an explicit maintenance window first. The two apps are
allowed to disagree; see `claude/gsi-pointapp-scope.md` for the reasoning.

## Structure

```
app.R              the Shiny app: map, controls, plots
R/gsi.R            the model, as pure functions (no Shiny) -- ported and
                    extended from GrowingSeasonIndex/R/gsi.R
R/fetch.R           fetch_point(lat, lon, year_to) -- on-demand ERA5 fetch via
                    Open-Meteo, adapted from GrowingSeasonIndex's
                    data-raw/fetch_openmeteo.R for a single arbitrary point
                    instead of a fixed site catalog
R/plots.R           every figure as pure functions (no Shiny)
data/cache/         per-point cached fetches (gitignored, not deployed --
                    rebuilds itself at runtime)
data-raw/make_sample_cache.R   generates a SYNTHETIC offline cache for the
                    app's default point, for UI/layout work -- see below
deploy.R            command-line deploy to Posit Connect -- see its header
docs/live-fuel-moisture.md   reference notes on gsi_to_lfm() / herb_load_transfer()
                    -- equations, plain-language explanation, and citations
                    for the GSI-to-fuel-moisture steps in R/gsi.R
docs/nfdrs4-notes.md   research notes comparing R/gsi.R against the actual
                    NFDRS4 reference implementation (firelab/NFDRS4) --
                    confirmed matches and several discrepancies (smoothing
                    window, green-up threshold default, the herb curing
                    formula) not yet decided on or implemented
```

## Iterating on the UI without hitting Open-Meteo

`Rscript data-raw/make_sample_cache.R` writes a synthetic-but-realistic
driving-data cache, shaped like Tucson's climate, straight into
`data/cache/` for every selectable year (1991-2025) at the app's default
point (32.22, -110.93). Once it's been run once, the sidebar's "Use offline
test point (no network)" button snaps to that point and loads instantly from
that cache, however many times you click it -- no Open-Meteo request, no
wait, regardless of what point or year you were last looking at. Delete the
matching `data/cache/32.220_-110.930_*.rds` files (or just check "ignore
cache") whenever you want real data back for that point.

This is fabricated data, not real ERA5 -- fine for checking that a plot
renders, a layout doesn't clip, or a new control does what it says, but
never a basis for an actual reading on GSI. See that script's header for how
it's built.

## Running it

```r
shiny::runApp(".", port = 7777)
```

Required packages: `shiny`, `bslib`, `leaflet`, `ggplot2`, `patchwork`,
`jsonlite`, `curl` (optional but recommended -- faster/more reliable HTTP
than base `readLines()`), `rsconnect` (for deploy only).

## Deploying

```r
Rscript deploy.R
```

Deploys to `viz.datascience.arizona.edu`, account `crimmins`, app name
`gsi-scout`, via `rsconnect::deployApp()` -- not RStudio's Republish button.
See `deploy.R`'s header for why, and for one-time auth setup.

## Version control

Tracked in git as of 2026-09-15. `.gitignore` and `.rscignore` were already
in place from the start (`.Renviron` and `data/cache/` -- except the
`.gitkeep` that keeps the empty folder -- are kept out of both git and the
deployed bundle; see `deploy.R`'s header for why `.Renviron` matters). No
remote configured yet -- `deploy.R`'s clean-working-tree check degrades
gracefully (skips with a message) until a repo exists here, so it's been a
no-op until now.

## Status (2026-09-15) -- working locally, UI iterated with Mike, not yet deployed

Built by Claude from the scoping conversation, then refined through several
rounds of hands-on review on Mike's machine -- things like a real map and a
real Shiny session, which the original scaffold couldn't check for itself in
its own build environment (see that environment's limits below, still
relevant to `R/fetch.R` specifically):

- **The model (`R/gsi.R`) and plotting (`R/plots.R`)** were smoke-tested
  against synthetic data early on, and have since been exercised live through
  many rounds of UI changes without issue -- `run_gsi()` with precipitation
  and soil moisture both toggled on and off, the 2-phase classifier, and the
  three daylength conventions.
- **`R/fetch.R` against the live Open-Meteo API is still the open item.**
  It's adapted directly from `fetch_openmeteo.R`, which *is* confirmed
  working (the cached `.rds` files already in
  `GrowingSeasonIndex/data/openmeteo/` prove that), but hasn't been
  confirmed end-to-end here yet -- click a point away from the offline test
  point, hit "Get data for this point," and confirm a fetch actually
  completes, if that hasn't been checked already.
- **UI has been substantially reworked** from the first scaffold: the
  per-variable threshold sliders now sit directly under each variable's plot
  on "Sub-index ramps" (one range slider per variable, not separate lo/hi
  pairs); the "GSI model" tab is just the plot, with a "How to use" tab
  added for new users; "Use offline test point (no network)" moved out of
  the everyday flow into a collapsed "Developer / testing" panel so a real
  user won't stumble into it.
- **Not yet deployed** to Posit Connect -- next step once this settles.
- No automated tests yet (Glass Box has `tests/test_gsi.R` etc. as a model
  to follow, if that's wanted here too).

## Attribution

Model core and fetch logic ported from `GrowingSeasonIndex` (Glass Box).
Jolly, Nemani & Running (2005) *Glob Change Biol* 11:619-632; Daham et al.
(2018) *J Water Clim Change* (precipitation control). FEMS default parameter
values from Cheryl's operational reference table, via `convo_on_gsi.docx`.
