# global.R — Shared setup and helper functions (conversational AI edition)
# -------------------------------------------------------------------------
# This version uses a persistent ellmer chat object with tool-calling so
# the LLM can have a multi-turn conversation AND update the plot via the
# update_plot() tool.  The shinychat package provides streaming chat bubbles.
# -------------------------------------------------------------------------

# ---------- Unified package bootstrap ----------
# Auto-installs any missing packages, loads all of them, and stops with a
# clear, actionable message if any package cannot be installed or loaded.
local({
  pkgs <- c("shiny", "ggplot2", "shinyjs", "jsonlite", "bslib",
            "ellmer", "coro", "promises", "readxl", "magick", "shinychat")
  miss <- pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
  if (length(miss) > 0) {
    message("Installing missing packages: ", paste(miss, collapse = ", "))
    
    # Set up user library directory (same as launch.ps1)
    usr_lib <- Sys.getenv("R_LIBS_USER")
    if (nchar(usr_lib) == 0) usr_lib <- file.path(Sys.getenv("APPDATA"), "R", "library")
    if (!dir.exists(usr_lib)) dir.create(usr_lib, recursive = TRUE, showWarnings = FALSE)
    .libPaths(c(usr_lib, .libPaths()))
    
    # Try multiple CRAN mirrors for reliability (match launch.ps1)
    repos <- c("https://cloud.r-project.org",
               "https://cran.rstudio.com",
               "https://posit.r-universe.dev")
    
    # Try binary first, then source if binaries unavailable
    install.packages(miss, repos = repos, lib = usr_lib, type = "both", quiet = FALSE)
    
    # Verify installation succeeded
    still_miss <- miss[!sapply(miss, requireNamespace, quietly = TRUE)]
    if (length(still_miss) > 0) {
      message("WARNING: Some packages could not be installed from binaries. Trying source...")
      install.packages(still_miss, repos = repos, lib = usr_lib, type = "source", quiet = FALSE)
      
      # Final check
      final_miss <- still_miss[!sapply(still_miss, requireNamespace, quietly = TRUE)]
      if (length(final_miss) > 0) {
        stop(
          "Failed to install packages: ", paste(final_miss, collapse = ", "), "\n\n",
          "This may be because:\n",
          "  1. No binary packages available for your R version\n",
          "  2. Rtools not installed (needed for source compilation)\n",
          "  3. Network/firewall issues\n\n",
          "Suggestions:\n",
          "  - Use the latest R from https://cran.r-project.org/ (R 4.4+ required)\n",
          "  - Install Rtools: https://cran.r-project.org/bin/windows/Rtools/\n",
          "  - Check your internet connection",
          call. = FALSE
        )
      }
    }
  }
  failed <- Filter(function(pkg) {
    !tryCatch({ library(pkg, character.only = TRUE); TRUE }, error = function(e) FALSE)
  }, pkgs)
  if (length(failed) > 0) {
    stop(
      "The following R packages could not be loaded:\n  ",
      paste(failed, collapse = ", "),
      "\n\nTo fix this, run in R:\n  install.packages(c(",
      paste0('"', failed, '"', collapse = ", "),
      "), repos = c('https://cloud.r-project.org', 'https://cran.rstudio.com', 'https://posit.r-universe.dev'))",
      call. = FALSE
    )
  }
})

# Set upload size limit (50MB) to prevent silent failures with large CSV/XLSX files
options(shiny.maxRequestSize = 50 * 1024^2)

# Serve the images/ folder at the /images/ URL path
addResourcePath("images", file.path(getwd(), "images"))

# ---------- Multi-provider config ----------
# Stores: provider, api_key, model  (as JSON)
get_config_path <- function() {
  dir <- tools::R_user_dir("ggplot-voice-copilot-multi-llm", which = "config")
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
  file.path(dir, "config.json")
}

load_saved_config <- function() {
  path <- get_config_path()
  if (!file.exists(path)) return(NULL)
  tryCatch({
    cfg <- jsonlite::fromJSON(readLines(path, warn = FALSE))
    
    # Backward compatibility: convert old single-key format to new multi-key format
    if (!is.null(cfg$api_key) && is.null(cfg$api_keys)) {
      old_provider <- cfg$provider %||% "openai"
      
      # Migrate removed providers (e.g., github_models) to openai.
      # GitHub PATs are NOT valid OpenAI keys — clear the key so the user is
      # prompted to enter a real API key rather than silently failing with 401.
      if (old_provider == "github_models") {
        message("[load_saved_config] Migrating github_models → openai (GitHub PAT cleared — not a valid OpenAI key)")
        old_provider <- "openai"
        cfg$api_key  <- ""  # force re-entry
      }
      
      cfg$api_keys <- list()
      cfg$api_keys[[old_provider]] <- cfg$api_key
      cfg$active_provider <- old_provider
      cfg$models <- list()
      cfg$models[[old_provider]] <- cfg$model %||% "gpt-4o"
    }
    
    # Validate active_provider is supported (handle multi-provider configs with invalid provider)
    valid_providers <- c("openai", "anthropic", "google", "ollama")
    if (!is.null(cfg$active_provider) && !(cfg$active_provider %in% valid_providers)) {
      message("[load_saved_config] Active provider '", cfg$active_provider, "' not supported, defaulting to openai")
      cfg$active_provider <- "openai"
    }
    
    # Validate: need at least one non-empty API key, or active provider is ollama
    has_keys <- !is.null(cfg$api_keys) && length(cfg$api_keys) > 0 &&
                any(nzchar(unlist(cfg$api_keys)))
    is_local <- identical(cfg$active_provider, "ollama")
    if (has_keys || is_local) return(cfg)
    NULL
  }, error = function(e) NULL)
}

save_config <- function(active_provider, api_keys, models) {
  # api_keys: named list of provider -> key (e.g., list(openai="sk-...", anthropic="sk-ant-..."))
  # models: named list of provider -> model (e.g., list(openai="gpt-4o", anthropic="claude-3-5-sonnet-20241022"))
  
  # Atomic write: write to temp file, then rename (prevents corruption if app crashes mid-write)
  config_path <- get_config_path()
  temp_path <- paste0(config_path, ".tmp")
  
  tryCatch({
    writeLines(
      jsonlite::toJSON(
        list(
          active_provider = active_provider,
          api_keys = api_keys,
          models = models
        ),
        auto_unbox = FALSE  # Keep lists as arrays
      ),
      temp_path
    )
    
    # Atomic rename (replaces existing file, or creates if not present).
    # file.rename() returns FALSE (not an error) when the OS can't rename
    # (e.g., antivirus lock on Windows) — check explicitly.
    if (!file.rename(temp_path, config_path)) {
      if (file.exists(temp_path)) file.remove(temp_path)
      stop("Could not save config: file rename failed (file may be locked by another process)",
           call. = FALSE)
    }
    
  }, error = function(e) {
    # Clean up temp file on error
    if (file.exists(temp_path)) file.remove(temp_path)
    stop("Failed to save config: ", e$message, call. = FALSE)
  })
}

# Provider labels shown in the UI badge
provider_label <- function(provider) {
  switch(provider,
    openai        = "OpenAI",
    anthropic     = "Anthropic",
    google        = "Google Gemini",
    ollama        = "Ollama (local)",
    provider
  )
}

# ---------- Default plot code ----------
DEFAULT_PLOT_CODE <- '
library(ggplot2)

p <- ggplot(mtcars, aes(x = wt, y = mpg)) +
  geom_point(color = "steelblue", size = 3) +
  labs(
    title = "Motor Trend Cars",
    x = "Weight (1000 lbs)",
    y = "Miles per Gallon"
  ) +
  theme_minimal()
'

# Detects renderable gg objects (ggplot, ggbreak, patchwork) while excluding
# non-renderable gg subclasses: theme objects (theme_bw()+theme()) and ggproto
# building blocks (Geom, Stat, Scale, Coord) which also carry "gg" in their class.
is_renderable_gg <- function(x) inherits(x, "gg") && !inherits(x, "theme") && !inherits(x, "ggproto")

# ---------- Safe plot evaluation ----------
safe_eval_plot <- function(code, extra_vars = list()) {
  make_env <- function() {
    env <- new.env(parent = globalenv())
    for (nm in names(extra_vars)) assign(nm, extra_vars[[nm]], envir = env)
    env
  }
  find_plot <- function(env, last_val = NULL) {
    if (exists("p", envir = env) && is_renderable_gg(env$p)) return(env$p)
    if (is_renderable_gg(last_val)) return(last_val)
    NULL
  }

  tryCatch(
    {
      env      <- make_env()
      last_val <- eval(parse(text = code), envir = env)
      plot_obj <- find_plot(env, last_val)
      if (!is.null(plot_obj)) {
        return(list(success = TRUE, plot = plot_obj, error = NULL))
      } else {
        return(list(
          success = FALSE, plot = NULL,
          error = "Code must produce a ggplot object — assign to 'p' or end with a bare ggplot() call."
        ))
      }
    },
    error = function(e) {
      return(list(success = FALSE, plot = NULL, error = conditionMessage(e)))
    },
    warning = function(w) {
      env      <- make_env()
      last_val <- suppressWarnings(eval(parse(text = code), envir = env))
      plot_obj <- find_plot(env, last_val)
      if (!is.null(plot_obj)) {
        return(list(success = TRUE, plot = plot_obj, error = NULL))
      } else {
        return(list(
          success = FALSE, plot = NULL,
          error = paste("Warning:", conditionMessage(w))
        ))
      }
    }
  )
}

# ---------- Null-coalescing operator ----------
`%||%` <- function(a, b) if (!is.null(a)) a else b

# ---------- File-name → valid R identifier ----------
# Used when naming uploaded datasets from their filenames.
make_r_varname <- function(filename) {
  nm <- tools::file_path_sans_ext(basename(filename))
  nm <- gsub("[^A-Za-z0-9_.]", "_", nm)   # replace non-identifier chars
  nm <- sub("^([0-9])", "_\\1", nm)        # can't start with a digit
  if (nchar(nm) == 0) nm <- "dataset"
  nm
}

# ---------- Script-preparation prompt for external LLMs ----------
# Users can download this to prepare their R scripts for use in the app.
SCRIPT_PREP_PROMPT <- paste0(
  "You are helping me prepare an R/ggplot2 script for use in ggplot Voice Copilot, ",
  "a Shiny app that lets users manipulate visualizations through conversation.\n\n",
  "Please rewrite the script I provide so it follows ALL of these rules:\n\n",
  "---\n\n",
  "1. LIBRARIES\n",
  "   Always include library(ggplot2) at the top, plus any other packages the code requires.\n\n",
  "2. DATA
",
  "   Single dataset:\n",
  "   - If the script reads external data from a file, replace the data-loading call with the\n",
  "     pre-loaded variable user_data (a data.frame already available in the app session).\n",
  "   - If you need the raw file path (e.g. for read_excel() with multiple sheets), use\n",
  "     user_data_path instead.\n",
  "   - Do NOT hardcode any file paths.\n\n",
  "   Multiple datasets:\n",
  "   - The app supports uploading multiple files at once (CSV, XLSX, XLS, RDS).\n",
  "   - Each file is automatically available as a named variable derived from its filename.\n",
  "     e.g. clinical_data.csv  → clinical_data\n",
  "         genomics.rds        → genomics\n",
  "         Metadata (2024).xlsx → Metadata__2024_\n",
  "   - The app shows the exact reference names in the Dataset panel after upload.\n",
  "   - Reference these variables DIRECTLY in your script — no read.csv() needed.\n",
  "   - Any plot can use any dataset. There is no requirement for a single master dataset;\n",
  "     you can merge them in the preamble if needed, or use them independently per plot.\n",
  "     Example (independent):\n",
  "       scatter <- ggplot(clinical_data, aes(x, y)) + geom_point()\n",
  "       bar     <- ggplot(genomics,      aes(gene, expr)) + geom_col()\n",
  "     Example (merged preamble):\n",
  "       master  <- merge(clinical_data, genomics, by = 'id')\n",
  "       scatter <- ggplot(master, aes(age, expression)) + geom_point()\n",
  "   - Do NOT hardcode any file paths.\n\n",
  "3. SINGLE PLOT\n",
  "   If the script produces only one visualization, assign the final ggplot object to a\n",
  "   variable named exactly p, OR let the ggplot() call be the last bare expression.\n\n",
  "4. MULTIPLE PLOTS\n",
  "   If the script produces more than one visualization:\n",
  "   - Assign each ggplot object to a distinct, descriptive variable name\n",
  "     (e.g. scatter, bar_chart, box_plot, line_trend).\n",
  "   - Every variable that holds a ggplot object is automatically detected by the app.\n",
  "   - If you name one of them p it will appear FIRST in the figure selector;\n",
  "     all other figures are listed in alphabetical order by variable name.\n",
  "   - You are NOT required to use p.\n",
  "   - Do NOT leave any plot as a bare (unassigned) expression in a multi-plot script.\n\n",
  "5. NO DISPLAY / EXPORT CALLS\n",
  "   Remove all print(), ggsave(), pdf(), png(), dev.off() calls.\n",
  "   The app handles all rendering and exporting automatically.\n\n",
  "6. CLEAN SIDE EFFECTS\n",
  "   Remove any cat(), message(), or unrelated print() statements that produce\n",
  "   non-plot console output, as these can interfere with app evaluation.\n\n",
  "---\n\n",
  "Here is the script to reformat:\n\n",
  "[PASTE YOUR SCRIPT HERE]\n"
)

# ---------- Multi-plot evaluation ----------
# Evaluates the full script and returns ALL ggplot objects found in the env.
# Returns: list(success, plots = named list of ggplot objects, error)
eval_multi_plots <- function(code, extra_vars = list()) {
  make_env <- function() {
    env <- new.env(parent = globalenv())
    for (nm in names(extra_vars)) assign(nm, extra_vars[[nm]], envir = env)
    env
  }

  collect_plots <- function(env, last_val = NULL) {
    all_vars <- ls(envir = env)
    plots <- Filter(Negate(is.null), lapply(stats::setNames(all_vars, all_vars), function(nm) {
      obj <- get(nm, envir = env)
      if (is_renderable_gg(obj)) obj else NULL   # "gg" catches ggplot + ggbreak + patchwork; excludes theme/ggproto
    }))
    # Also capture bare last expression if it is a gg object and not already captured
    if (is_renderable_gg(last_val) && !any(sapply(plots, identical, last_val))) {
      plots[["(plot)"]] <- last_val
    }
    # Sort: 'p' first, then alphabetical
    nms <- names(plots)
    nms <- c(intersect("p", nms), sort(setdiff(nms, "p")))
    plots[nms]
  }

  run_eval <- function(suppress_warn) {
    env      <- make_env()
    last_val <- if (suppress_warn) {
      suppressWarnings(eval(parse(text = code), envir = env))
    } else {
      eval(parse(text = code), envir = env)
    }
    list(env = env, last_val = last_val)
  }

  # ggbreak "invalid called." root cause:
  # ggbreak's internal .ggbreak$scale_break() walks sys.calls() and throws
  # "invalid called." if ANY anonymous function is on the call stack.
  # Ellmer's tool dispatch uses anonymous closures, so every ggbreak eval
  # from an LLM tool call fails.  Fix: patch scale_break to remove that
  # call-stack check.  The check is purely defensive (not functional), so
  # removing it is safe.  We also unload/reload the namespace first so any
  # stale S7 state from previous ggplot_build() calls is cleared.
  if (grepl("ggbreak|scale_[xy]_break|scale_[xy]_cut", code, perl = TRUE)) {
    if (isNamespaceLoaded("ggbreak")) {
      message("[eval_multi_plots] Resetting ggbreak namespace...")
      try({
        if ("package:ggbreak" %in% search()) {
          detach("package:ggbreak", unload = TRUE, force = TRUE)
        } else {
          unloadNamespace("ggbreak")
        }
      }, silent = TRUE)
    }
    # Re-load and immediately patch .ggbreak$scale_break to strip the
    # anonymous-function call-stack check.  The user's library(ggbreak) in
    # the eval'd code will be a no-op (already loaded), so the patch sticks.
    # Use getFromNamespace() to get a reference to the environment, then
    # mutate it in-place (environments are reference objects in R so this
    # directly modifies the namespace copy).
    message("[eval_multi_plots] Loading and patching ggbreak...")
    suppressWarnings(suppressMessages(
      tryCatch(library(ggbreak), error = function(e) NULL)
    ))
    try({
      patched <- function(axis, breaks, scales, ticklabels = NULL,
                          expand = TRUE, space = 0.1, symbol = NULL) {
        structure(list(axis = axis, breaks = breaks, scales = scales,
                       ticklabels = ticklabels, expand = expand,
                       space = space, symbol = symbol),
                  class = "ggbreak_params")
      }
      .gb_env <- getFromNamespace(".ggbreak", "ggbreak")
      .gb_env$scale_break <- patched
      message("[eval_multi_plots] ggbreak patched OK")
    }, silent = FALSE)
  }

  tryCatch({
    # Use withCallingHandlers so warnings are muffled WITHOUT a non-local exit.
    # tryCatch(warning=...) aborts mid-execution, which corrupts packages like
    # ggbreak that use withCallingHandlers internally and expect to resume after
    # a warning (causing "invalid called." on subsequent calls).
    message("[eval_multi_plots] Starting eval...")
    res <- withCallingHandlers(
      run_eval(FALSE),
      warning = function(w) {
        message("[eval_multi_plots] Warning (muffled): ", conditionMessage(w))
        invokeRestart("muffleWarning")
      }
    )
    message("[eval_multi_plots] Eval complete. Collecting plots...")
    plots <- collect_plots(res$env, res$last_val)
    message("[eval_multi_plots] Plots found: ", length(plots),
            " names: ", paste(names(plots), collapse = ", "))
    if (!is.null(res$last_val)) {
      message("[eval_multi_plots] last_val class: ", paste(class(res$last_val), collapse = ", "))
    }
    if (length(plots) == 0) {
      return(list(success = FALSE, plots = list(),
                  error = "Code must produce at least one gg object (ggplot, ggbreak, patchwork)."))
    }
    list(success = TRUE, plots = plots, error = NULL)
  },
  error = function(e) {
    msg <- conditionMessage(e)
    message("[eval_multi_plots] ERROR: ", msg)
    message("[eval_multi_plots] Call: ", deparse(conditionCall(e)))
    # "invalid called." is a ggbreak state-corruption error caused by a stale
    # restart token from a previous ggplot_build call.  A single retry after
    # gc() is usually enough to recover once ggbreak's internal refs are cleared.
    if (grepl("invalid called", msg, fixed = TRUE)) {
      message("[eval_multi_plots] ggbreak state error — retrying after gc()...")
      gc()
      tryCatch({
        res2 <- withCallingHandlers(
          run_eval(FALSE),
          warning = function(w) {
            message("[eval_multi_plots] Warning (retry, muffled): ", conditionMessage(w))
            invokeRestart("muffleWarning")
          }
        )
        plots2 <- collect_plots(res2$env, res2$last_val)
        message("[eval_multi_plots] Retry succeeded. Plots: ", length(plots2))
        if (length(plots2) == 0)
          return(list(success = FALSE, plots = list(),
                      error = "Code must produce at least one gg object."))
        list(success = TRUE, plots = plots2, error = NULL)
      }, error = function(e2) {
        message("[eval_multi_plots] Retry also failed: ", conditionMessage(e2))
        list(success = FALSE, plots = list(), error = conditionMessage(e2))
      })
    } else {
      list(success = FALSE, plots = list(), error = msg)
    }
  })
}

# ---------- Script splitting for per-plot isolation ----------
# Splits a multi-plot script into a shared preamble + individual plot blocks.
# Returns list(preamble = "...", plot_codes = list(name1 = "...", name2 = "..."))
# Single-plot scripts return NULL (caller should not use isolation).
split_script <- function(code, extra_vars = list()) {
  exprs <- tryCatch(parse(text = code, keep.source = TRUE), error = function(e) NULL)
  if (is.null(exprs) || length(exprs) == 0) return(NULL)

  # Get source text for each top-level expression using srcref.
  # keep.source = TRUE is required to get srcrefs in Rscript.exe (non-interactive) mode;
  # without it, getOption("keep.source") defaults to FALSE and attr(exprs,"srcref") is NULL.
  src_refs <- attr(exprs, "srcref")
  if (is.null(src_refs) || length(src_refs) == 0) {
    message("[split_script] No srcrefs available — falling back to full-script mode")
    return(NULL)
  }
  lines    <- strsplit(code, "\n")[[1]]

  # Build an environment to eval expressions one by one
  env <- new.env(parent = globalenv())
  for (nm in names(extra_vars)) assign(nm, extra_vars[[nm]], envir = env)

  # Track which expressions belong to which plot
  expr_groups        <- character(length(exprs))   # "preamble" or plot name
  known_plots        <- character(0)
  plot_dep_snapshots <- list()                      # per-plot preamble value snapshots

  for (i in seq_along(exprs)) {
    pre_vars <- ls(envir = env)
    pre_gg   <- Filter(function(nm) is_renderable_gg(get(nm, envir = env)), pre_vars)

    tryCatch(
      suppressWarnings(eval(exprs[[i]], envir = env)),
      error   = function(e) NULL,
      warning = function(w) NULL
    )

    post_vars <- ls(envir = env)
    post_gg   <- Filter(function(nm) is_renderable_gg(get(nm, envir = env)), post_vars)
    new_gg    <- setdiff(post_gg, pre_gg)

    # Also detect re-assignment to an existing plot var (e.g. p <- p + geom_...)
    # Check if expression is an assignment to a known plot var
    expr_text <- deparse(exprs[[i]])
    assigned_to <- NULL
    if (length(expr_text) > 0) {
      m <- regmatches(expr_text[1], regexec("^\\s*([A-Za-z._][A-Za-z0-9._]*)\\s*<-", expr_text[1]))
      if (length(m[[1]]) == 2) assigned_to <- m[[1]][2]
    }

    if (length(new_gg) > 0) {
      # New plot(s) created — assign this expression to the first new plot
      plot_name <- new_gg[1]
      expr_groups[i] <- plot_name
      known_plots <- union(known_plots, new_gg)
      # Snapshot preamble variable values visible to this plot at the moment it was
      # first created (pre_vars = state before this expression ran).  Capturing now
      # prevents later helper reassignments for sibling plots from contaminating
      # this plot's dep context.  Exclude extra_vars (uploaded datasets) and any
      # gg objects already produced by earlier plot blocks.
      .snap_nms <- setdiff(pre_vars, c(names(extra_vars), pre_gg))
      plot_dep_snapshots[[plot_name]] <- setNames(
        lapply(.snap_nms, function(.snm)
          tryCatch(get(.snm, envir = env), error = function(e) NULL)
        ),
        .snap_nms
      )
    } else if (!is.null(assigned_to) && assigned_to %in% known_plots) {
      # Re-assignment to existing plot var (e.g. p <- p + theme(...))
      expr_groups[i] <- assigned_to
    } else {
      expr_groups[i] <- "preamble"
    }
  }

  # Only apply isolation if we found multiple plots
  if (length(known_plots) <= 1) return(NULL)

  # Convert srcref to line ranges and extract text
  preamble_lines <- character(0)
  plot_code_lines <- stats::setNames(
    vector("list", length(known_plots)),
    known_plots
  )
  for (nm in known_plots) plot_code_lines[[nm]] <- character(0)

  for (i in seq_along(exprs)) {
    sr <- src_refs[[i]]
    if (is.null(sr)) next
    first_line <- sr[1]
    last_line  <- sr[3]
    # Grab any comment lines immediately above this expression
    comment_start <- first_line
    while (comment_start > 1 && grepl("^\\s*#", lines[comment_start - 1])) {
      comment_start <- comment_start - 1
    }
    block <- lines[comment_start:last_line]

    if (expr_groups[i] == "preamble") {
      preamble_lines <- c(preamble_lines, block)
    } else {
      plot_code_lines[[expr_groups[i]]] <- c(plot_code_lines[[expr_groups[i]]], block)
    }
  }

  list(
    preamble          = paste(preamble_lines, collapse = "\n"),
    plot_codes        = lapply(plot_code_lines, function(bl) paste(bl, collapse = "\n")),
    plot_dep_contexts = plot_dep_snapshots
  )
}

# ---------- Preamble dependency extraction ----------
# Compact structural summary of a data.frame — no raw rows.
.format_dep_df <- function(nm, df) {
  nc   <- ncol(df)
  nr   <- nrow(df)
  cols <- vapply(seq_len(nc), function(j) {
    col <- df[[j]]
    cn  <- names(df)[j]
    cl  <- class(col)[1]
    desc <- if (is.numeric(col)) {
      rng <- range(col, na.rm = TRUE)
      paste0("<", cl, " [", round(rng[1], 2), ", ", round(rng[2], 2), "]>")
    } else if (is.factor(col) || is.character(col)) {
      lvls    <- if (is.factor(col)) levels(col) else unique(col)
      preview <- paste(head(lvls, 10L), collapse = ", ")
      suffix  <- if (length(lvls) > 10L) ", ..." else ""
      paste0("<", cl, ": ", preview, suffix, ">")
    } else {
      paste0("<", cl, ">")
    }
    paste0("  ", cn, " ", desc)
  }, character(1L))
  paste0("# ", nm, ": data.frame [", nr, " rows x ", nc, " cols]\n",
         "# Columns:\n", paste(cols, collapse = "\n"))
}

# Extracts serialised preamble dep context for the active plot's LLM system prompt.
# plot_code   : source text of the active plot block
# dep_context : named list of preamble variable values (from split_script())
# Returns a prompt-section character string, or NULL when there is nothing to inject.
extract_preamble_deps <- function(plot_code, dep_context,
                                  max_obj_chars   = 800L,
                                  max_total_chars = 4000L) {
  if (is.null(dep_context) || length(dep_context) == 0) return(NULL)
  if (is.null(plot_code)   || nchar(trimws(plot_code)) == 0) return(NULL)

  all_var_names <- names(dep_context)

  # Strip comment-only lines before scanning to avoid false matches in comments
  # or banner strings that happen to contain a helper's name.
  code_lines <- strsplit(plot_code, "\n")[[1]]
  code_text  <- paste(code_lines[!grepl("^\\s*#", code_lines)], collapse = "\n")

  # Returns the subset of candidates whose names appear as whole words in text.
  find_refs <- function(text, candidates) {
    Filter(function(nm) {
      pat <- paste0("\\b",
                    gsub("([.+*?^${}()|\\[\\]\\\\])", "\\\\\\1", nm),
                    "\\b")
      grepl(pat, text, perl = TRUE)
    }, candidates)
  }

  # Serialises one preamble variable to a compact, prompt-ready string.
  serialize_dep <- function(nm, val) {
    if (is.null(val)) return(NULL)
    tryCatch({
      if (is.data.frame(val))  return(.format_dep_df(nm, val))
      if (is.function(val)) {
        body_text <- paste(deparse(val, control = NULL), collapse = "\n")
        return(paste0(nm, " <- ", body_text))
      }
      if (is.environment(val) ||
          inherits(val, "gg") || inherits(val, "ggplot") ||
          inherits(val, "externalptr")) return(NULL)
      # Atomic / list: exact literal for small objects, structural summary for large.
      n_elem <- tryCatch(
        if (is.list(val)) length(unlist(val, recursive = TRUE, use.names = FALSE))
        else               length(val),
        error = function(e) length(val)
      )
      if (n_elem <= 100L) {
        paste0(nm, " <- ", paste(deparse(val, control = NULL), collapse = "\n"))
      } else {
        cap <- utils::capture.output(utils::str(val, max.level = 2L))
        paste0("# ", nm, " [structure]:\n# ", paste(cap, collapse = "\n# "))
      }
    }, error = function(e) NULL)
  }

  parts            <- character(0)
  serialized_names <- character(0)

  # Pass 1: variables directly referenced in the active plot block.
  for (nm in find_refs(code_text, all_var_names)) {
    s <- serialize_dep(nm, dep_context[[nm]])
    if (!is.null(s)) {
      if (nchar(s) > max_obj_chars)
        s <- paste0(substr(s, 1L, max_obj_chars), "\n# ... [truncated]")
      parts            <- c(parts, s)
      serialized_names <- c(serialized_names, nm)
    }
  }

  # Pass 2: transitive references inside the already-serialised dep text
  # (e.g. custom_labeller's body references age_map).
  if (length(parts) > 0) {
    remaining <- setdiff(all_var_names, serialized_names)
    for (nm in find_refs(paste(parts, collapse = "\n"), remaining)) {
      s <- serialize_dep(nm, dep_context[[nm]])
      if (!is.null(s)) {
        if (nchar(s) > max_obj_chars)
          s <- paste0(substr(s, 1L, max_obj_chars), "\n# ... [truncated]")
        parts <- c(parts, s)
      }
    }
  }

  if (length(parts) == 0) return(NULL)

  body <- paste(parts, collapse = "\n\n")
  if (nchar(body) > max_total_chars)
    body <- paste0(substr(body, 1L, max_total_chars),
                   "\n# ... [preamble deps truncated — context budget exceeded]")

  paste0(
    "## Plot Setup Variables (read-only context)\n",
    "These variables are defined in the shared preamble and referenced by this plot's code.\n",
    "Do NOT redefine or include them in your update_plot() response — ",
    "only return the modified active plot block.\n\n",
    body
  )
}

# Rebuilds the full script from preamble + per-plot code blocks.
reconstitute_script <- function(preamble, plot_codes) {
  parts <- c(preamble)
  for (nm in names(plot_codes)) {
    parts <- c(parts, "", plot_codes[[nm]])
  }
  paste(parts, collapse = "\n")
}

# ---------- Script package helpers ----------

# Parses all library() / require() calls from user-supplied code and returns
# a character vector of unique package names found.
extract_script_packages <- function(code) {
  # Detect library(pkg) / require(pkg)
  m1 <- gregexpr(
    '(?:library|require)\\s*\\(\\s*["\']?([A-Za-z0-9._]+)["\']?',
    code, perl = TRUE
  )
  raw1 <- regmatches(code, m1)[[1]]
  pkgs1 <- if (length(raw1) > 0) {
    p <- sub('(?:library|require)\\s*\\(\\s*["\']?', '', raw1, perl = TRUE)
    sub('["\']?$', '', trimws(p))
  } else character(0)

  # Detect pkg::function() namespace-qualified calls (LLM often uses these)
  m2 <- gregexpr('([A-Za-z0-9._]+)::(?:[A-Za-z0-9._]+)', code, perl = TRUE)
  raw2 <- regmatches(code, m2)[[1]]
  pkgs2 <- if (length(raw2) > 0) sub('::.*$', '', raw2) else character(0)

  # Exclude base/stats packages that are always available
  always_loaded <- c('base', 'stats', 'utils', 'methods', 'graphics',
                     'grDevices', 'datasets')
  unique(setdiff(c(pkgs1, pkgs2), always_loaded))
}

# Installs any packages in `pkgs` that are not yet available.
# Returns list(installed = <newly installed>, failed = <could not install>).
install_script_packages <- function(pkgs) {
  missing_pkgs <- pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
  if (length(missing_pkgs) == 0) return(list(installed = character(0), failed = character(0)))
  message("Installing packages from script: ", paste(missing_pkgs, collapse = ", "))
  cran_repos <- c("https://cloud.r-project.org", "https://cran.rstudio.com",
                  "https://posit.r-universe.dev")
  tryCatch(
    install.packages(missing_pkgs, repos = cran_repos, quiet = TRUE),
    error = function(e) NULL
  )
  still_missing <- missing_pkgs[!sapply(missing_pkgs, requireNamespace, quietly = TRUE)]
  list(
    installed = setdiff(missing_pkgs, still_missing),
    failed    = still_missing
  )
}

# ---------- Conversational system prompt ----------
CONV_BASE_PROMPT <- paste0(
  "You are a friendly, expert R/ggplot2 data visualization assistant. ",
  "The user's current visualization is shown in the plot panel on the right. ",
  "You help the user interactively explore and refine their plot through a natural conversation.\n\n",
  "TOOL USE — to change the visualization, call the update_plot() tool:\n",
  "  - Pass complete, runnable ggplot2 R code\n",
  "  - The code MUST assign the final plot to variable 'p' OR end with a bare ggplot() expression\n",
  "  - Always include library(ggplot2) (and any other required libraries) at the top\n",
  "  - If the user has uploaded a CSV/XLSX/RDS file, reference it as 'user_data'\n",
  "  - Do NOT write raw R code in your conversational text — only use the tool to apply changes\n\n",
  "After the tool call succeeds, reply with a short bullet list of EVERY visual change you made to the plot — ",
  "including changes the user did NOT explicitly ask for (e.g. side-effects of keeping style consistent). ",
  "Format each bullet as: '• <what changed> — <new value or description>'. ",
  "Example: '• Point size — increased to 5\\n• Point shape — changed to triangle\\n• Legend position — moved to bottom (to keep layout balanced)'. ",
  "Do NOT just say 'Done.' List all changes, even minor ones.\n",
  "CRITICAL: Do NOT include any R code, variable names, or function names (such as plot.title, element_text, or hjust) in your descriptions.\n",
  "If a journal/style skill is active, add one line noting whether the changes comply.\n",
  "The tool result contains a CODE DIFF. Use it to ensure your bullet list is complete and accurate — do NOT repeat raw diff lines.\n",
  "ONLY if you detect a statistical change (geom type, aes() variables, stat/method/formula arguments,\n",
  "data filters or transformations), add ONE bullet: '⚠️ STATISTICAL CHANGE: <brief description>'.\n",
  "If no statistical change, omit the statistical change bullet entirely.\n",
  "For general ggplot2 / R questions, just answer conversationally — no tool call required.\n",
  "If the tool returns a code error, acknowledge it and try again with corrected code.\n",
  "##### SCOPE GUARDRAIL #####\n",
  "You are ONLY a ggplot2 visualization assistant. You can ONLY help with:\n",
  "  - Editing, refining, or explaining the current ggplot2 visualization\n",
  "  - ggplot2 / R plotting questions (geoms, themes, scales, colors, labels, etc.)\n",
  "If the user asks about ANYTHING else (coding in other languages, general knowledge, math, ",
  "writing, advice, non-R topics, etc.), do NOT answer. Instead reply with exactly:\n",
  "  'I'm a ggplot2 visualization assistant and can only help with editing or discussing your plot. ",
  "Please ask me something about your visualization!'\n",
  "Do NOT apologize at length. Do NOT engage with off-topic content at all.\n",
  "###########################\n",
  "NEVER repeat the conversation history. NEVER output the user's previous or current messages.\n",
  "##### HARD STOP RULE #####\n",
  "Your response MUST end immediately after the bullet list describing the tool changes. ",
  "Do NOT output the user's next message. Do NOT add dummy user actions. Do NOT continue the dialogue. ",
  "Never write what the user might say next. NEVER echo or paraphrase the user's message. ",
  "STOP GENERATING IMMEDIATELY after your sentence.\n",
  "##########################\n\n",
  "IMPORTANT — PRESERVE EXISTING STYLE:\n",
  "When modifying a plot, keep ALL existing theme() calls, color scales, fill scales, ",
  "labs(), coord_*(), facet_*(), and any other styling EXACTLY as they are, ",
  "UNLESS the user explicitly asks you to change them. ",
  "Do NOT replace theme_minimal(), theme_bw(), or any custom theme with the default gray background. ",
  "Copy every line of the original code verbatim, changing only what the user requested."
)

build_conv_system_prompt <- function(journal_instructions = NULL,
                                     data_summary = NULL,
                                     current_code = NULL,
                                     active_plot_name = NULL,
                                     all_plot_names = NULL,
                                     sheet_names = NULL,
                                     preamble_deps = NULL) {
  prompt <- CONV_BASE_PROMPT

  # Multi-plot context: tell LLM which plot is active (code is already isolated to this plot)
  if (!is.null(all_plot_names) && length(all_plot_names) > 1) {
    prompt <- paste0(
      prompt,
      "\n\n## Multi-Plot Context\n",
      "The uploaded script defines ", length(all_plot_names), " plots: ",
      paste(all_plot_names, collapse = ", "), ".\n",
      "You are currently editing **", active_plot_name, "**.\n",
      "The code shown below is ONLY the code block for this plot. ",
      "When calling update_plot(), return ONLY the modified code for **", active_plot_name, "** — ",
      "the app handles merging it back into the full script automatically.\n",
      "Do NOT include shared setup code (library calls, data loading, themes) — that is handled separately.\n",
      "CRITICAL: Keep the EXACT same variable name as in the provided code (e.g. `", active_plot_name, "`). ",
      "Do NOT rename it to 'p' or any other name."
    )
  }

  if (!is.null(preamble_deps) && nchar(trimws(preamble_deps)) > 0) {
    prompt <- paste0(prompt, "\n\n", trimws(preamble_deps))
  }

  if (!is.null(current_code) && nchar(trimws(current_code)) > 0) {
    prompt <- paste0(
      prompt,
      "\n\n## Current Plot Code\nThe plot currently displayed is produced by this code:\n```r\n",
      trimws(current_code), "\n```"
    )
  }

  if (!is.null(journal_instructions) && nchar(trimws(journal_instructions)) > 0) {
    prompt <- paste0(
      prompt,
      "\n\n## Journal-Specific Requirements\n", trimws(journal_instructions),
      "\nAlways apply these requirements to every visualization you generate."
    )
  }

  prompt
}

# ---------- Create a fresh per-session chat object ----------
# update_plot_fn: an R function(code) that updates the reactive plot — captured
#   from the server closure so it can write to rv$current_code / rv$current_plot.
#
# provider: "openai" | "anthropic" | "google" | "ollama"
# api_key : API key string (empty string / ignored for Ollama)
# model   : model name string
create_session_chat <- function(provider  = "openai",
                                api_key   = "",
                                model     = "gpt-4o",
                                journal_instructions = NULL,
                                data_summary = NULL, current_code = NULL,
                                active_plot_name = NULL, all_plot_names = NULL,
                                sheet_names = NULL,
                                preamble_deps = NULL,
                                update_plot_fn) {
  system_prompt <- build_conv_system_prompt(
    journal_instructions = journal_instructions,
    data_summary         = data_summary,
    current_code         = current_code,
    active_plot_name     = active_plot_name,
    all_plot_names       = all_plot_names,
    sheet_names          = sheet_names,
    preamble_deps        = preamble_deps
  )

  chat <- switch(provider,
    openai = ellmer::chat_openai(
      api_key       = api_key,
      model         = model,
      system_prompt = system_prompt
    ),
    anthropic = ellmer::chat_claude(
      api_key       = api_key,
      model         = model,
      system_prompt = system_prompt
    ),
    google = ellmer::chat_google_gemini(
      api_key       = api_key,
      model         = model,
      system_prompt = system_prompt
    ),
    ollama = ellmer::chat_ollama(
      model         = model,
      system_prompt = system_prompt
    ),
    stop("Unknown provider: ", provider)
  )

  update_plot_tool <- ellmer::tool(
    update_plot_fn,
    "Update the ggplot2 visualization with new R code. Always call this tool when the user requests a plot change, never just write code in chat text.",
    arguments = list(
      code = ellmer::type_string(
        "Complete, valid ggplot2 R code for the ACTIVE plot only. In a multi-plot script, return ONLY the code for the currently active plot — the app merges it back automatically. Include library() calls only for single-plot scripts. Reference uploaded CSV/XLSX/RDS data as 'user_data'."
      )
    ),
    name = "update_plot"
  )

  chat$register_tool(update_plot_tool)
  chat
}

# ---------- Helper: generate default starter code for a dataset ----------
generate_default_code <- function(dataset_name, df) {
  nums  <- names(df)[sapply(df, is.numeric)]
  x_col <- if (length(nums) >= 1) nums[1] else names(df)[1]
  y_col <- if (length(nums) >= 2) nums[2] else names(df)[1]

  clean_name <- gsub(" \\(.*", "", dataset_name)
  df_ref <- if (grepl("^Upload", clean_name)) {
    "user_data"
  } else {
    switch(clean_name,
      "mtcars"   = "mtcars",
      "iris"     = "iris",
      "diamonds" = "diamonds_sample",
      clean_name
    )
  }

  sprintf('
library(ggplot2)

p <- ggplot(%s, aes(x = %s, y = %s)) +
  geom_point(color = "steelblue", size = 3) +
  labs(
    title = "%s Dataset",
    x = "%s",
    y = "%s"
  ) +
  theme_minimal()
', df_ref, x_col, y_col, clean_name, x_col, y_col)
}

# ---------- Generate data summary string for the system prompt ----------
summarize_dataframe <- function(df) {
  if (is.null(df)) return(NULL)

  cols <- sapply(names(df), function(col) {
    cl <- class(df[[col]])[1]
    if (cl %in% c("numeric", "integer", "double")) {
      paste0(col, " (", cl, ", range: ", min(df[[col]], na.rm = TRUE),
             " to ", max(df[[col]], na.rm = TRUE), ")")
    } else if (cl %in% c("factor", "character")) {
      levels_preview <- paste(head(unique(df[[col]]), 5), collapse = ", ")
      paste0(col, " (", cl, ", values: ", levels_preview, ")")
    } else {
      paste0(col, " (", cl, ")")
    }
  })

  paste0(
    "DataFrame: ", nrow(df), " rows x ", ncol(df), " columns\n",
    "Columns:\n  - ", paste(cols, collapse = "\n  - ")
  )
}

# ---------- Git-style LCS line diff ----------
# Returns a unified-diff-style string (- removed, + added) using LCS.
#
# Vectorized DP: the inner j-loop is eliminated by observing that LCS values
# are non-decreasing along each row — so the left-to-right dependency
# dp[i+1,j+1] = max(raw[j], dp[i+1,j]) is exactly cummax(raw).
# Per-row cost drops from O(n) R iterations to two vectorized calls (pmax +
# cummax), reducing total DP cost from O(m*n) R-loop iterations to O(m).
#
# Backtracking uses a pre-allocated character vector + rev() at the end,
# avoiding the O(n²) cost of c(new_item, result) prepend in the old version.
lcs_diff <- function(old_lines, new_lines) {
  m <- length(old_lines)
  n <- length(new_lines)

  # Fast-path edge cases
  if (m == 0L && n == 0L) return("(no differences)")
  if (m == 0L) return(paste(paste0("+ ", new_lines), collapse = "\n"))
  if (n == 0L) return(paste(paste0("- ", old_lines), collapse = "\n"))

  # Build LCS DP table — one R loop over rows only (inner j loop vectorized)
  dp <- matrix(0L, m + 1L, n + 1L)
  idx_n   <- seq_len(n)
  idx_np1 <- 2L:(n + 1L)
  for (i in seq_len(m)) {
    # match_vec: TRUE where old_lines[i] == new_lines[j], for all j at once
    match_vec <- old_lines[i] == new_lines          # vectorized comparison
    # raw[j] = max(dp[i,j] + match, dp[i,j+1])  — diagonal vs above
    raw <- pmax(dp[i, idx_n] + match_vec, dp[i, idx_np1])
    # cummax propagates the left-neighbour dependency: dp[i+1,j+1] = max(raw[j], dp[i+1,j])
    # This is correct because LCS is row-non-decreasing, so cummax = running max
    dp[i + 1L, idx_np1] <- cummax(raw)
  }

  # Backtrack — pre-allocated vector, filled in reverse, reversed at end
  # (avoids O(n²) repeated vector copying from c(item, result) prepend)
  buf <- character(m + n)   # worst-case: all lines differ
  k   <- 0L
  i   <- m; j <- n
  while (i > 0L || j > 0L) {
    if (i > 0L && j > 0L && old_lines[i] == new_lines[j]) {
      i <- i - 1L; j <- j - 1L          # unchanged line — skip (no context)
    } else if (j > 0L && (i == 0L || dp[i + 1L, j] >= dp[i, j + 1L])) {
      k <- k + 1L; buf[k] <- paste0("+ ", new_lines[j]); j <- j - 1L
    } else {
      k <- k + 1L; buf[k] <- paste0("- ", old_lines[i]); i <- i - 1L
    }
  }
  if (k == 0L) "(no differences)" else paste(rev(buf[seq_len(k)]), collapse = "\n")
}

# ---------- Capture a gg object as an ellmer image content object ----------
# Used to pass the current plot image to the LLM alongside the user's message.
# Uses png()+print()+dev.off() instead of ggsave() to avoid corrupting ggbreak's
# internal withRestarts state (ggsave calls ggplot_build which triggers ggbreak's
# restart mechanism; after it returns the cached restart token becomes invalid,
# causing "invalid called." on the next eval of ggbreak code).
ggplot_image_content <- function(plot_obj, width = 7, height = 5, dpi = 100, cache_path = NULL) {
  if (is.null(plot_obj) || !inherits(plot_obj, "gg") || inherits(plot_obj, "theme") || inherits(plot_obj, "ggproto")) return(NULL)
  # Use pre-rendered PNG if available — avoids re-rendering ggbreak objects
  # (a second ggplot_build() call corrupts ggbreak's S7 internal state)
  if (!is.null(cache_path) && file.exists(cache_path)) {
    message("[plot_image] Using cached PNG for LLM (skipping re-render). class: ",
            paste(class(plot_obj), collapse = ", "))
    return(ellmer::content_image_file(cache_path, resize = "low"))
  }
  message("[plot_image] Capturing plot for LLM. class: ", paste(class(plot_obj), collapse = ", "))
  tryCatch({
    tmp <- tempfile(fileext = ".png")
    on.exit({
      if (grDevices::dev.cur() != 1L) grDevices::dev.off()
      unlink(tmp)
    }, add = TRUE)
    grDevices::png(tmp,
                  width  = as.integer(width  * dpi),
                  height = as.integer(height * dpi),
                  res    = as.integer(dpi),
                  bg     = "white")
    withCallingHandlers(
      print(plot_obj),
      warning = function(w) invokeRestart("muffleWarning")
    )
    grDevices::dev.off()
    message("[plot_image] png OK — ", tmp)
    ellmer::content_image_file(tmp, resize = "low")
  }, error = function(e) {
    message("[plot_image] ERROR during capture: ", conditionMessage(e))
    message("[plot_image] Call: ", deparse(conditionCall(e)))
    NULL
  })
}

# ---------- Export a ggplot to a temp file ----------
export_plot <- function(plot_obj, format = "png", width_in = 8, height_in = 6, dpi = 300) {
  tryCatch({
    tmp <- tempfile(fileext = paste0(".", format))
    if (format == "png") {
      png(tmp, width = width_in * dpi, height = height_in * dpi, res = dpi)
    } else if (format == "pdf") {
      grDevices::pdf(tmp, width = width_in, height = height_in)
    } else if (format == "svg") {
      grDevices::svg(tmp, width = width_in, height = height_in)
    }
    print(plot_obj)
    grDevices::dev.off()
    tmp
  }, error = function(e) {
    try(grDevices::dev.off(), silent = TRUE)
    NULL
  })
}
