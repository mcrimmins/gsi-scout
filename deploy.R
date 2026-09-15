## -----------------------------------------------------------------------------
## deploy.R -- command-line deploy to Posit Connect.
##
##   Rscript deploy.R
##
## Deliberately NOT the RStudio Republish button: that button deploys whatever
## is in the working directory and silently re-targets whichever app was last
## deployed to -- an ambiguity that already bit NFDRSChartBuilder once. This
## script names the target explicitly (so it's reviewable before it runs) and
## checks the working tree first. See claude/gsi-pointapp-scope.md.
##
## Auth: reads the API key from the environment (CONNECT_API_KEY), same
## pattern as NFDRSChartBuilder. Register it once per machine with:
##
##   rsconnect::connectApiUser(account = "crimmins",
##                              server = "viz.datascience.arizona.edu",
##                              apiKey = Sys.getenv("CONNECT_API_KEY"))
##
## after putting CONNECT_API_KEY (and anything else secret) in .Renviron --
## .rscignore keeps .Renviron out of the deployed bundle, and .gitignore keeps
## it out of git.
##
## First run creates the app on Connect (no need to pre-create it in the web
## UI) and writes rsconnect/viz.datascience.arizona.edu/crimmins/gsi-scout.dcf
## locally with the resulting appId, which every run after that targets.
## -----------------------------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a) || is.na(a) || !nzchar(a)) b else a

SERVER   <- "viz.datascience.arizona.edu"
ACCOUNT  <- "crimmins"
APP_NAME <- "gsi-scout"

git_status <- function() {
  if (!nzchar(Sys.which("git"))) return(list(clean = NA, branch = NA_character_))
  st <- tryCatch(system2("git", c("status", "--porcelain"), stdout = TRUE),
                error = function(e) NA)
  br <- tryCatch(system2("git", c("rev-parse", "--abbrev-ref", "HEAD"), stdout = TRUE),
                error = function(e) NA_character_)
  list(clean = if (identical(st, NA)) NA else length(st) == 0, branch = br)
}

g <- git_status()

if (isFALSE(g$clean)) {
  ans <- readline(sprintf(
    "Working tree has uncommitted changes (branch: %s). Deploy anyway? [y/N] ",
    g$branch %||% "?"))
  if (!identical(tolower(trimws(ans)), "y")) stop("Deploy cancelled.", call. = FALSE)
} else if (is.na(g$clean)) {
  message("git not found on PATH -- skipping the clean-working-tree check.")
} else {
  message(sprintf("Working tree clean, branch: %s", g$branch %||% "?"))
}

if (!nzchar(Sys.getenv("CONNECT_API_KEY")) &&
    nrow(rsconnect::accounts(server = SERVER)) == 0) {
  stop("No rsconnect account registered for ", SERVER, " and CONNECT_API_KEY ",
       "is not set. Run rsconnect::connectApiUser() once (see this file's ",
       "header) before deploying.", call. = FALSE)
}

message(sprintf("Deploying to %s / %s / %s ...", SERVER, ACCOUNT, APP_NAME))

rsconnect::deployApp(
  appDir      = ".",
  appName     = APP_NAME,
  account     = ACCOUNT,
  server      = SERVER,
  forceUpdate = TRUE
)

message("Done. Deployment record: rsconnect/", SERVER, "/", ACCOUNT, "/", APP_NAME, ".dcf")
