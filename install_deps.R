# install_deps.R -- installs or upgrades GeomWhisper's R packages.
# The launchers run this in its own Rscript process before Shiny starts, because an
# R session that has loaded a package holds its DLL open and Windows cannot replace it.
# Sourcing this file only defines the package list and helpers; running it installs.

GEOMWHISPER_PACKAGES <- c("shiny", "ggplot2", "shinyjs", "jsonlite", "bslib",
                          "ellmer", "coro", "promises", "readxl", "magick", "shinychat")
GEOMWHISPER_MINIMUM_VERSIONS <- c(ellmer = "0.5.0", shinychat = "0.5.0")

# Package versions are pinned to CRAN as of this date and tested with R 4.5.3; the
# launchers accept any R 4.5.x. To move to newer packages, change the date, rerun
# the tests, and rebuild both installers.
GEOMWHISPER_SNAPSHOT_DATE <- "2026-09-27"
GEOMWHISPER_PACKAGE_SOURCES <- list(
  list(label = paste0("Posit Package Manager snapshot ", GEOMWHISPER_SNAPSHOT_DATE),
       repos = c(CRAN = paste0("https://packagemanager.posit.co/cran/", GEOMWHISPER_SNAPSHOT_DATE))),
  list(label = "CRAN, latest versions (fallback)",
       repos = c(CRAN = "https://cloud.r-project.org",
                 RStudio = "https://cran.rstudio.com",
                 Posit = "https://posit.r-universe.dev"))
)

# Kept apart from the user's R library so RStudio or other projects cannot lock or change it.
geomwhisper_library <- function() {
  # Packages built for one R minor version do not work with another.
  r_version <- paste(R.version$major, sub("\\..*", "", R.version$minor), sep = ".")
  base <- if (.Platform$OS.type == "windows") Sys.getenv("LOCALAPPDATA") else
    file.path(path.expand("~"), "Library", "Application Support")
  file.path(base, "GeomWhisper", "R", r_version, "library")
}

use_geomwhisper_library <- function() {
  lib <- geomwhisper_library()
  dir.create(lib, recursive = TRUE, showWarnings = FALSE)
  .libPaths(lib, include.site = FALSE)
  Sys.setenv(R_LIBS_USER = lib)
  lib
}

parse_requirements <- function(fields) {
  entries <- trimws(unlist(strsplit(fields[!is.na(fields)], ",", fixed = TRUE)))
  pattern <- "^([[:alnum:].]+)[[:space:]]*(\\(([<>=]+)[[:space:]]*([^)[:space:]]+)[[:space:]]*\\))?"
  parts <- regmatches(entries, regexec(pattern, entries))
  parts <- parts[lengths(parts) > 0]
  data.frame(
    package = vapply(parts, `[`, "", 2),
    op      = vapply(parts, `[`, "", 4),
    version = vapply(parts, `[`, "", 5),
    stringsAsFactors = FALSE
  )
}

version_unmet <- function(installed, op, required) {
  tryCatch({
    installed <- package_version(installed)
    required  <- package_version(required)
    switch(op, ">=" = installed < required, ">" = installed <= required,
           "==" = installed != required, FALSE)
  }, error = function(e) FALSE)
}

# Packages that are missing, below a minimum version, or older than a version required
# by another package in the dependency tree described by `db`. `install.packages()` only
# installs missing dependencies, so outdated ones must be named explicitly.
packages_to_install <- function(db, installed,
                                pkgs = GEOMWHISPER_PACKAGES,
                                minimums = GEOMWHISPER_MINIMUM_VERSIONS) {
  # Rows follow .libPaths() order, so the first copy of a package is the one R loads.
  installed <- installed[!duplicated(installed[, "Package"]), , drop = FALSE]
  db <- db[!duplicated(db[, "Package"]), , drop = FALSE]
  have <- installed[, "Version"]
  names(have) <- installed[, "Package"]

  deps <- tools::package_dependencies(pkgs, db = db, recursive = TRUE,
                                      which = c("Depends", "Imports", "LinkingTo"))
  tree <- setdiff(unique(c(pkgs, unlist(deps, use.names = FALSE))), "R")

  need <- setdiff(tree, names(have))
  for (pkg in intersect(names(minimums), names(have))) {
    if (version_unmet(have[[pkg]], ">=", minimums[[pkg]])) need <- c(need, pkg)
  }
  for (pkg in intersect(tree, db[, "Package"])) {
    reqs <- parse_requirements(db[match(pkg, db[, "Package"]), c("Depends", "Imports", "LinkingTo")])
    for (i in seq_len(nrow(reqs))) {
      dep <- reqs$package[i]
      if (dep %in% names(have) && version_unmet(have[[dep]], reqs$op[i], reqs$version[i])) {
        need <- c(need, dep)
      }
    }
  }
  unique(need)
}

# Loads each package in a fresh R process so this session never loads package DLLs.
load_failures <- function(pkgs = GEOMWHISPER_PACKAGES) {
  rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  script <- tempfile(fileext = ".R")
  on.exit(unlink(script))
  writeLines(c(
    sprintf(".libPaths(c(%s), include.site = FALSE)", paste(sprintf('"%s"', .libPaths()), collapse = ", ")),
    sprintf("pkgs <- c(%s)", paste(sprintf('"%s"', pkgs), collapse = ", ")),
    'for (p in pkgs) tryCatch(loadNamespace(p), error = function(e) cat("LOADFAIL", p, gsub("[[:space:]]+", " ", conditionMessage(e)), "\\n"))'
  ), script)
  out <- suppressWarnings(system2(rscript, c("--vanilla", shQuote(script)), stdout = TRUE, stderr = TRUE))
  sub("^LOADFAIL ", "", grep("^LOADFAIL ", out, value = TRUE))
}

# Installs packages that are not installed yet (e.g. ones requested by plot code),
# trying the pinned snapshot before CRAN so versions match the app's own packages.
install_missing_packages <- function(pkgs) {
  not_installed <- function(p) p[!nzchar(vapply(p, function(x) system.file(package = x), ""))]
  for (source in GEOMWHISPER_PACKAGE_SOURCES) {
    pkgs <- not_installed(pkgs)
    if (!length(pkgs)) break
    message("Installing ", paste(pkgs, collapse = ", "), " from ", source$label)
    tryCatch(
      utils::install.packages(pkgs, repos = source$repos, quiet = TRUE),
      error = function(e) message("Package install failed: ", conditionMessage(e))
    )
  }
  invisible(not_installed(pkgs))
}

setup_failed <- function(detail) {
  cat("\nERROR: ", detail, "\n\n",
      "Try the following, then relaunch GeomWhisper:\n",
      "  - Close any other GeomWhisper window that is still running. A package\n",
      "    that is in use cannot be replaced.\n",
      "  - Check your internet connection. A corporate proxy may block package downloads.\n",
      sep = "")
  1L
}

run_install <- function() {
  lib <- use_geomwhisper_library()
  cat("R ", as.character(getRversion()), "; package libraries: ",
      paste(.libPaths(), collapse = "; "), "\n", sep = "")

  installed <- utils::installed.packages(noCache = TRUE)
  need <- packages_to_install(installed, installed)
  if (!length(need)) {
    failures <- load_failures()
    if (length(failures)) {
      return(setup_failed(paste0("These R packages failed to load:\n  ",
                                 paste(failures, collapse = "\n  "))))
    }
    cat("All required R packages are installed.\n")
    return(0L)
  }
  cat("Missing or outdated: ", paste(need, collapse = ", "), "\n", sep = "")

  used <- character(0)
  for (source in GEOMWHISPER_PACKAGE_SOURCES) {
    for (type in c("binary", "source")) {
      installed <- utils::installed.packages(noCache = TRUE)
      local_need <- packages_to_install(installed, installed)
      if (!length(local_need)) break
      db <- tryCatch(
        suppressWarnings(utils::available.packages(repos = source$repos, type = type)),
        error = function(e) NULL
      )
      if (is.null(db) || !nrow(db)) {
        cat("Could not reach ", source$label, " (", type, " packages).\n", sep = "")
        next
      }
      need <- unique(c(local_need, packages_to_install(db, installed)))
      # A failed install leaves 00LOCK folders behind, and they block every later install.
      unlink(list.files(lib, pattern = "^00LOCK", full.names = TRUE), recursive = TRUE, force = TRUE)
      cat("Installing ", type, " packages from ", source$label, ": ",
          paste(need, collapse = ", "), "\n", sep = "")
      used <- union(used, source$label)
      tryCatch(
        utils::install.packages(need, lib = lib, repos = source$repos, type = type, available = db),
        error = function(e) cat("Install error: ", conditionMessage(e), "\n", sep = "")
      )
    }
  }
  if (length(used)) cat("Package source used: ", paste(used, collapse = "; "), "\n", sep = "")

  installed <- utils::installed.packages(noCache = TRUE)
  remaining <- packages_to_install(installed, installed)
  if (length(remaining)) {
    found <- installed[match(remaining, installed[, "Package"]), "Version"]
    details <- paste0(remaining, ifelse(is.na(found), " (not installed)", paste0(" ", found)))
    return(setup_failed(paste0("These R packages are missing or out of date: ",
                               paste(details, collapse = ", "))))
  }

  failures <- load_failures()
  if (length(failures)) {
    return(setup_failed(paste0("These R packages failed to load:\n  ",
                               paste(failures, collapse = "\n  "))))
  }
  cat("R packages are ready.\n")
  0L
}

if (sys.nframe() == 0L) quit(save = "no", status = run_install())
