# server.R — Shiny server for ggplot Voice Copilot (conversational AI edition)
# -----------------------------------------------------------------------------
# Architecture:
#   • A persistent ellmer chat object (chat_obj) is created per session and
#     keeps the full conversation history → the LLM remembers previous turns.
#   • The LLM calls the update_plot() tool whenever it needs to update the
#     visualization.  The tool function writes to rv$current_code / rv$current_plot.
#   • shinychat::chat_ui() in the sidebar renders streaming chat bubbles.
#   • Voice (Web Speech API) fires voice_text → update_chat_user_input() to
#     populate the chat input and auto-submit, keeping voice invisible in the UI.
# -----------------------------------------------------------------------------

server <- function(input, output, session) {

  # Load saved config once at session start (outside reactiveValues so it runs once)
  .saved_cfg <- load_saved_config()

  # ====== Reactive Values ======
  rv <- reactiveValues(
    current_code         = trimws(DEFAULT_PLOT_CODE),
    current_plot         = NULL,
    data_summary         = NULL,
    code_history         = list(),
    error_msg            = NULL,
    eval_warnings        = character(),
    user_data            = NULL,
    active_df            = NULL,
    # Multi-LLM provider state
    provider             = .saved_cfg$active_provider %||% .saved_cfg$provider %||% "openai",
    api_keys             = .saved_cfg$api_keys %||% list(),     # Named list: provider -> key
    models               = .saved_cfg$models %||% list(),       # Named list: provider -> model
    configured           = !is.null(.saved_cfg),
    journal_instructions = "",
    code_load_msg        = NULL,
    # Multi-plot support
    multi_plots          = NULL,
    active_plot_name     = NULL,
    # Excel multi-sheet support
    user_data_path       = NULL,
    sheet_names          = NULL,
    # Per-plot isolation: preamble + individual plot code blocks
    preamble_code        = NULL,       # shared setup code (libraries, data, themes)
    plot_codes           = NULL,        # named list of per-plot code strings
    plot_dep_contexts    = NULL,        # named list: plot_name -> preamble value snapshot
    preamble_deps_text   = NULL,        # serialised deps for the active plot (prompt text)
    extra_datasets       = list(),      # named list: varname -> data.frame for multi-file uploads
    init_failed          = FALSE         # TRUE after a failed init_chat(); cleared on Save Config
  )

  # Per-plot reactive store — each thumbnail only re-renders when its OWN entry changes.
  rv_single_plots <- reactiveValues()

  # Computes and stores preamble dep context for one active plot from a split result.
  # Pass split_result = NULL to clear dep state (single-plot / error / reset paths).
  .store_deps <- function(split_result, active_nm) {
    if (!is.null(split_result) && !is.null(active_nm) &&
        active_nm %in% names(split_result$plot_dep_contexts %||% list())) {
      rv$plot_dep_contexts  <- split_result$plot_dep_contexts
      rv$preamble_deps_text <- extract_preamble_deps(
        split_result$plot_codes[[active_nm]],
        split_result$plot_dep_contexts[[active_nm]]
      )
    } else if (!is.null(split_result)) {
      rv$plot_dep_contexts  <- split_result$plot_dep_contexts
      rv$preamble_deps_text <- NULL
    } else {
      rv$plot_dep_contexts  <- NULL
      rv$preamble_deps_text <- NULL
    }
  }

  # Persistent chat object: one per session, reset on dataset/code/journal change
  chat_obj <- reactiveVal(NULL)
  chat_generation <- reactiveVal(0L)
  search_intent <- reactiveVal(FALSE)
  request_in_flight <- reactiveVal(FALSE)
  # Guard: prevents double init_chat() when reset_plot programmatically fires updateSelectInput
  skip_dataset_init_chat <- reactiveVal(FALSE)

  plot_warnings <- reactiveVal(character())
  all_plot_warnings <- reactive(classify_plot_warnings(c(rv$eval_warnings, plot_warnings())))
  plot_render_count <- reactiveVal(0L)
  # Render count at the latest chat plot update; the warning note waits for a later render.
  warning_note_after <- reactiveVal(NULL)

  # ====== Tool: update the ggplot from inside the LLM response ======
  #
  # Called by ellmer automatically when the LLM emits a tool-use block.
  # Reads rv via isolate() (safe outside reactive context) and writes directly.
  #
  # Per-plot isolation: when rv$plot_codes is set, 'code' is just the active
  # plot block. We eval preamble + block, splice back, and reconstitute.
  update_plot_fn <- function(code) {
    active_df        <- isolate(rv$active_df)
    current_code     <- isolate(rv$current_code)
    active_plot_name <- isolate(rv$active_plot_name)
    user_data_path   <- isolate(rv$user_data_path)
    preamble_code    <- isolate(rv$preamble_code)
    plot_codes       <- isolate(rv$plot_codes)
    extra_datasets   <- isolate(rv$extra_datasets)

    extra <- c(list(user_data = active_df, user_data_path = user_data_path), extra_datasets)

    # Determine what code to evaluate
    is_isolated <- !is.null(preamble_code) && !is.null(plot_codes) && !is.null(active_plot_name)
    if (is_isolated) {
      # LLM returned only the active plot's code block — eval preamble + this block
      eval_code <- paste(preamble_code, code, sep = "\n\n")
      # For diff: compare against the previous plot block, not full script
      old_plot_code <- plot_codes[[active_plot_name]] %||% ""
      message("[update_plot_fn] Isolated mode: eval preamble (", nchar(preamble_code),
              " chars) + plot block (", nchar(code), " chars)")
    } else {
      eval_code     <- code
      old_plot_code <- current_code
      message("[update_plot_fn] Full-script mode: eval ", nchar(code), " chars")
    }

    # Auto-install any packages referenced in the LLM-generated code
    # (catches both library(pkg) and pkg::function() patterns)
    llm_pkgs <- extract_script_packages(code)
    if (length(llm_pkgs) > 0) {
      missing_pkgs <- llm_pkgs[!sapply(llm_pkgs, requireNamespace, quietly = TRUE)]
      if (length(missing_pkgs) > 0) {
        message("[update_plot_fn] Installing missing packages: ", paste(missing_pkgs, collapse = ", "))
        install_missing_packages(missing_pkgs)
      }
    }

    result <- eval_multi_plots(eval_code, extra_vars = extra)
    message("[update_plot_fn] eval_multi_plots returned success=", result$success,
            if (!result$success) paste0(" error=", result$error) else "")

    if (result$success) {
      rv$eval_warnings <- result$warnings %||% character()
      hist <- isolate(rv$code_history)
      hist <- append(hist, list(list(code = current_code, plot_name = active_plot_name)))
      if (length(hist) > 20) hist <- hist[(length(hist) - 19):length(hist)]
      rv$code_history <- hist

      plots <- result$plots

      if (is_isolated) {
        # Splice modified block back into plot_codes and reconstitute
        plot_codes[[active_plot_name]] <- code
        rv$plot_codes   <- plot_codes
        rv$current_code <- reconstitute_script(preamble_code, plot_codes)

        # Find the plot — prefer the canonical active_plot_name, fall back to first
        # (handles rare case where LLM still renamed the variable despite instructions)
        plot_obj <- plots[[active_plot_name]] %||% plots[[1]]
        rv$current_plot                    <- plot_obj
        rv_single_plots[[active_plot_name]] <- plot_obj
        # Keep rv$active_plot_name unchanged — canonical name stays authoritative
      } else if (length(plots) > 1) {
        rv$current_code <- code
        new_name <- if (!is.null(active_plot_name) && active_plot_name %in% names(plots)) {
          active_plot_name
        } else {
          names(plots)[1]
        }
        rv$multi_plots      <- plots
        rv$active_plot_name <- new_name
        rv$current_plot     <- plots[[new_name]]
        for (nm in names(plots)) rv_single_plots[[nm]] <- plots[[nm]]
        # Refresh split so LLM gets up-to-date per-plot code blocks on next init_chat
        split2 <- split_script(code, extra_vars = extra)
        if (!is.null(split2)) {
          rv$preamble_code <- split2$preamble
          rv$plot_codes    <- split2$plot_codes
        } else {
          rv$preamble_code <- NULL
          rv$plot_codes    <- NULL
        }
        .store_deps(split2, new_name)
      } else {
        rv$current_code     <- code
        rv$multi_plots      <- NULL
        rv$active_plot_name <- names(plots)[1]
        rv$current_plot     <- plots[[1]]
      }
      rv$error_msg <- NULL
      warning_note_after(isolate(plot_render_count()))
      message("[update_plot] SUCCESS — ", length(plots), " plot(s) updated")

      # Compute a git-style LCS diff (order-preserving, handles duplicates correctly)
      diff_text <- lcs_diff(
        strsplit(trimws(old_plot_code %||% ""), "\n")[[1]],
        strsplit(trimws(code),                  "\n")[[1]]
      )

      paste0(
        "Plot updated successfully.\n\n",
        "CODE DIFF (- removed, + added):\n", diff_text, "\n\n",
        "Silently analyze this diff. ",
        "ONLY if you detect a statistical change (geom type, aes() variables, stat/method/formula arguments, ",
        "data filters or transformations) include ONE line: ⚠️ STATISTICAL CHANGE: <brief description>. ",
        "If no statistical change, do not mention the diff at all."
      )
    } else {
      msg <- paste0("Code error: ", result$error, " — please provide corrected code.")
      message("[update_plot] FAIL — ", result$error)
      rv$error_msg <- paste("AI code error:", result$error)
      msg
    }
  }

  # ====== Create a fresh session chat ======
  #
  # init_chat() is called:
  #   1. When a PAT is saved/loaded
  #   2. When the dataset changes (fresh context)
  #   3. When new code is manually loaded
  #   4. When journal skills are updated
  #
  # This creates a new chat with an up-to-date system prompt (current code,
  # data summary, journal instructions) and registers the update_plot tool.
  # When clear_ui = FALSE the visible conversation bubbles are preserved
  # (used when switching between figures so history is not wiped).
  init_chat <- function(clear_ui = TRUE) {
    provider   <- isolate(rv$provider)
    api_keys   <- isolate(rv$api_keys)
    models     <- isolate(rv$models)
    configured <- isolate(rv$configured)
    
    # Get API key and model for current provider from stored multi-provider data
    api_key <- api_keys[[provider]] %||% ""
    model   <- models[[provider]] %||% "gpt-5-mini"
    
    journal_instructions <- isolate(rv$journal_instructions)
    data_summary         <- isolate(rv$data_summary)
    current_code         <- isolate(rv$current_code)
    multi_plots          <- isolate(rv$multi_plots)
    active_plot_name     <- isolate(rv$active_plot_name)
    sheet_names          <- isolate(rv$sheet_names)
    plot_codes           <- isolate(rv$plot_codes)

    if (!isTRUE(configured)) {
      chat_obj(NULL)
      return(invisible(NULL))
    }

    # Clear the visual chat history in the UI (skipped when switching figures)
    if (clear_ui) chat_clear("chat")

    all_plot_names <- if (!is.null(multi_plots) && length(multi_plots) > 1) names(multi_plots) else NULL

    # Per-plot isolation: send only the active plot's code block to the LLM
    code_for_llm <- current_code
    if (!is.null(plot_codes) && !is.null(active_plot_name) && active_plot_name %in% names(plot_codes)) {
      code_for_llm <- plot_codes[[active_plot_name]]
      message("[init_chat] Isolated mode: sending only ", active_plot_name,
              " block (", nchar(code_for_llm), " chars) instead of full script (",
              nchar(current_code), " chars)")
    }

    tryCatch({
      chat <- create_session_chat(
        provider             = provider,
        api_key              = api_key,
        model                = model,
        journal_instructions = journal_instructions,
        data_summary         = data_summary,
        current_code         = code_for_llm,
        active_plot_name     = active_plot_name,
        all_plot_names       = all_plot_names,
        sheet_names          = sheet_names,
        preamble_deps        = isolate(rv$preamble_deps_text)
      )
      chat_obj(chat)
      chat_generation(isolate(chat_generation()) + 1L)
      rv$init_failed <- FALSE
      message("[init_chat] Chat session created — provider: ", provider, " model: ", model)
    }, error = function(e) {
      message("[init_chat] Failed: ", conditionMessage(e))
      rv$init_failed <- TRUE
      chat_obj(NULL)
      showNotification(
        paste0("Could not connect to ", provider, ": ", conditionMessage(e),
               " \u2014 check your API key and model name."),
        type = "error", duration = 8
      )
    })
  }

  # ====== Clean shutdown (desktop packaging) ======
  if (identical(Sys.getenv("GGPLOT_VOICE_COPILOT_DESKTOP"), "1")) {
    session$onSessionEnded(function() {
      stopApp()
      q("no")
    })
  }

  # Expose setup mode for conditional panel
  output$setup_mode <- reactive({ !isTRUE(rv$configured) })
  outputOptions(output, "setup_mode", suspendWhenHidden = FALSE)

  # Dynamic model badge in sidebar
  output$model_badge <- renderUI({
    if (!isTRUE(rv$configured)) return(span("Not configured"))
    provider <- rv$provider
    model    <- rv$models[[provider]] %||% "unknown"
    span(paste0(model, " \u00b7 ", provider_label(provider)))
  })

  search_available <- reactive({
    isTRUE(rv$configured) && web_search_supported(rv$provider)
  })

  observeEvent(input$web_search_enabled, {
    requested <- isTRUE(input$web_search_enabled)
    if (isTRUE(request_in_flight())) {
      updateCheckboxInput(session, "web_search_enabled", value = search_intent())
      return()
    }
    search_intent(requested)
  }, ignoreInit = FALSE)

  observe({
    available <- search_available()
    if (isTRUE(request_in_flight()) || !available) {
      shinyjs::disable("web_search_enabled")
    } else {
      shinyjs::enable("web_search_enabled")
    }
  })

  output$web_search_status <- renderUI({
    provider <- rv$provider
    if (!web_search_supported(provider)) {
      return(div(
        class = "web-search-help unavailable",
        tags$i(class = "fa-solid fa-circle-info"),
        " Web search is unavailable for Ollama. Your checked preference is retained."
      ))
    }
    div(
      class = "web-search-help",
      tags$i(class = "fa-solid fa-shield-halved"),
      " When checked, provider search queries may use the current chat, plot code, column names, sample values, numeric ranges, and errors."
    )
  })

  # ====== AI Settings ======
  # Helper: pull the correct model input for the selected provider
  get_model_input <- function() {
    switch(input$llm_provider,
      openai        = input$model_openai,
      anthropic     = input$model_anthropic,
      google        = input$model_google,
      ollama        = input$model_ollama,
      "gpt-5-mini"
    )
  }

  # Helper: pull the correct API key input for the selected provider
  get_api_key_input <- function() {
    switch(input$llm_provider,
      openai        = input$api_key_openai  %||% "",
      anthropic     = input$api_key_anthropic %||% "",
      google        = input$api_key_google  %||% "",
      ollama        = "",
      ""
    )
  }

  observeEvent(input$save_config_btn, {
    provider <- input$llm_provider
    
    # Collect ALL API keys from ALL provider input fields
    all_api_keys <- list(
      openai    = trimws(input$api_key_openai %||% ""),
      anthropic = trimws(input$api_key_anthropic %||% ""),
      google    = trimws(input$api_key_google %||% "")
      # ollama = no key needed
    )
    # Remove empty keys
    all_api_keys <- all_api_keys[nchar(all_api_keys) > 0]
    
    # Collect ALL models from ALL provider input fields
    all_models <- list(
      openai    = trimws(input$model_openai %||% ""),
      anthropic = trimws(input$model_anthropic %||% ""),
      google    = trimws(input$model_google %||% ""),
      ollama    = trimws(input$model_ollama %||% "")
    )
    # Remove empty models
    all_models <- all_models[nchar(all_models) > 0]
    
    # Get current provider's API key and model
    current_api_key <- get_api_key_input()
    current_model   <- trimws(get_model_input() %||% "")
    
    # Validation: active provider needs API key (except Ollama)
    if (provider != "ollama" && nchar(current_api_key) == 0) {
      output$setup_error_msg <- renderUI(
        div(class = "error-msg",
            tags$i(class = "fa fa-exclamation-triangle"),
            " Please enter an API key for ", provider, ".")
      )
      return()
    }
    if (nchar(current_model) == 0) {
      output$setup_error_msg <- renderUI(
        div(class = "error-msg",
            tags$i(class = "fa fa-exclamation-triangle"),
            " Please enter a model name.")
      )
      return()
    }

    # Save all keys and models
    save_config(provider, all_api_keys, all_models)
    
    # Update reactive values
    rv$provider    <- provider
    rv$api_keys    <- all_api_keys
    rv$models      <- all_models
    rv$configured  <- TRUE
    rv$init_failed <- FALSE   # clear failure flag so auto-init observer can re-fire
    output$setup_error_msg <- renderUI(NULL)
    init_chat()
  })

  # Clear setup error when user changes provider (old error may not apply to new one)
  observeEvent(input$llm_provider, {
    output$setup_error_msg <- renderUI(NULL)
  }, ignoreInit = TRUE)

  # ── Authors modal ──
  # ── Authors modal ──
  .authors <- list(
    list(name = "Tushar Patni", url = "https://www.linkedin.com/in/tusharpatni"),
    list(name = "Jade Wang",    url = "https://artsci.tamu.edu/statistics/contact/profiles/jade-wang.html"),
    list(name = "Yimei Li",     url = "https://www.stjude.org/people/l/yimei-li.html")
  )

  observeEvent(input$show_authors, {
    showModal(modalDialog(
      title     = tagList(tags$i(class = "fa-solid fa-feather-pointed"), " About the Authors"),
      easyClose = TRUE,
      footer    = NULL,
      size      = "s",
      div(
        class = "authors-stack",
        tagList(lapply(seq_along(.authors), function(i) {
          a <- .authors[[i]]
          tagList(
            div(
              class = "author-entry",
              tags$a(
                href   = a$url,
                target = "_blank",
                rel    = "noopener noreferrer",
                tags$span(class = "author-name", a$name)
              )
            ),
            if (i < length(.authors)) tags$div(class = "author-rule") else NULL
          )
        }))
      )
    ))
  })

  observeEvent(input$change_settings, {
    rv$configured <- FALSE
    chat_obj(NULL)
    # Pre-fill the settings screen with the current saved values
    prefill_settings()
  })

  # Pre-fill the settings UI inputs from rv state (used on change_settings and startup restore)
  prefill_settings <- function() {
    prov      <- isolate(rv$provider)
    api_keys  <- isolate(rv$api_keys)
    models    <- isolate(rv$models)

    updateSelectInput(session, "llm_provider", selected = prov)

    # Update ALL per-provider API key fields from saved data
    if (!is.null(api_keys$openai) && nchar(api_keys$openai) > 0) {
      updateTextInput(session, "api_key_openai", value = api_keys$openai)
    }
    if (!is.null(api_keys$anthropic) && nchar(api_keys$anthropic) > 0) {
      updateTextInput(session, "api_key_anthropic", value = api_keys$anthropic)
    }
    if (!is.null(api_keys$google) && nchar(api_keys$google) > 0) {
      updateTextInput(session, "api_key_google", value = api_keys$google)
    }

    # Update ALL per-provider model fields from saved data
    if (!is.null(models$openai) && nchar(models$openai) > 0) {
      updateTextInput(session, "model_openai", value = models$openai)
    }
    if (!is.null(models$anthropic) && nchar(models$anthropic) > 0) {
      updateTextInput(session, "model_anthropic", value = models$anthropic)
    }
    if (!is.null(models$google) && nchar(models$google) > 0) {
      updateTextInput(session, "model_google", value = models$google)
    }
    if (!is.null(models$ollama) && nchar(models$ollama) > 0) {
      updateTextInput(session, "model_ollama", value = models$ollama)
    }
  }

  # Auto-init chat on startup if config already saved.
  # req(!rv$init_failed) breaks the retry loop: after a failed init, this
  # observer will not fire again until the user saves new config (which resets the flag).
  observe({
    req(rv$configured)
    req(!rv$init_failed)
    # The dataset observer creates the first chat once the data summary exists.
    req(rv$data_summary)
    if (is.null(chat_obj())) init_chat()
  })

  # Pre-populate settings UI fields on startup if config exists
  observe({
    req(!is.null(.saved_cfg))
    # Only run once - use isolate to prevent reactive loop
    isolate({
      if (length(rv$api_keys) > 0 || length(rv$models) > 0) {
        prefill_settings()
      }
    })
  })

  # ====== Dataset Management ======
  observe({
    req(input$dataset)

    # Reset sheet/path/extra-datasets state before loading
    rv$user_data_path  <- NULL
    rv$sheet_names     <- NULL
    rv$extra_datasets  <- list()
    # Clear active_df immediately so data_info blanks while waiting for file upload
    if (input$dataset == "Upload File\u2026") rv$active_df <- NULL

    df <- switch(input$dataset,
      "mtcars"            = mtcars,

      "Upload File\u2026" = {
        req(input$csv_upload)
        files <- input$csv_upload   # data.frame: name, size, type, datapath

        loaded     <- list()
        names_used <- character(0)

        for (i in seq_len(nrow(files))) {
          ext      <- tolower(tools::file_ext(files$name[i]))
          datapath <- files$datapath[i]

          df_i <- tryCatch({
            if (ext %in% c("xlsx", "xls")) {
              sheets <- tryCatch(readxl::excel_sheets(datapath), error = function(e) NULL)
              if (i == 1) { rv$user_data_path <- datapath; rv$sheet_names <- sheets }
              as.data.frame(readxl::read_excel(datapath))
            } else if (ext == "rds") {
              if (i == 1) rv$user_data_path <- datapath
              obj <- readRDS(datapath)
              if (is.data.frame(obj)) obj else as.data.frame(obj)
            } else {
              if (i == 1) rv$user_data_path <- datapath
              read.csv(datapath, stringsAsFactors = FALSE)
            }
          }, error = function(e) {
            showNotification(
              paste0("Could not read '\u2018", files$name[i], "'\u2019: ", conditionMessage(e)),
              type = "error", duration = 10
            )
            NULL
          })
          if (is.null(df_i)) next

          # Sanitize filename to valid R identifier, deduplicate if needed
          nm <- make_r_varname(files$name[i])
          if (nm %in% names_used) {
            j <- 2
            while (paste0(nm, "_", j) %in% names_used) j <- j + 1
            nm <- paste0(nm, "_", j)
          }
          names_used    <- c(names_used, nm)
          loaded[[nm]]  <- df_i
        }

        rv$extra_datasets <- loaded
        loaded[[1]]   # active_df = first file (kept as user_data for backward compat)
      }
    )

    rv$active_df    <- df
    rv$data_summary <- summarize_dataframe(df)

    current    <- isolate(rv$current_code)
    clean_name <- gsub(" \\(.*", "", input$dataset)
    code_keyword <- if (grepl("^Upload", clean_name)) "user_data" else clean_name

    if (input$dataset == "mtcars" && grepl("user_data", current, fixed = TRUE)) {
      rv$code_history     <- append(isolate(rv$code_history), list(list(code = current, plot_name = isolate(rv$active_plot_name))))
      rv$current_code     <- trimws(DEFAULT_PLOT_CODE)
      rv$current_plot     <- NULL
      rv$multi_plots      <- NULL
      rv$active_plot_name <- NULL
      rv$preamble_code    <- NULL
      rv$plot_codes       <- NULL
      rv$plot_dep_contexts  <- NULL
      rv$preamble_deps_text <- NULL
    } else if (input$dataset != "mtcars" && !grepl(code_keyword, current, ignore.case = TRUE)) {
      new_code <- generate_default_code(input$dataset, df)
      rv$code_history     <- append(isolate(rv$code_history), list(list(code = current, plot_name = isolate(rv$active_plot_name))))
      rv$current_code     <- new_code
      rv$current_plot     <- NULL
      rv$multi_plots      <- NULL
      rv$active_plot_name <- NULL
      rv$preamble_code    <- NULL
      rv$plot_codes       <- NULL
      rv$plot_dep_contexts  <- NULL
      rv$preamble_deps_text <- NULL
    }

    # Reset conversation with fresh data + code context
    if (isolate(skip_dataset_init_chat())) {
      skip_dataset_init_chat(FALSE)
    } else {
      req(rv$configured)
      init_chat()
    }
  })

  output$data_info <- renderText({
    extra <- rv$extra_datasets
    if (!is.null(extra) && length(extra) > 1) {
      lines <- vapply(names(extra), function(nm) {
        df <- extra[[nm]]
        paste0("  ", nm, "  (", nrow(df), " rows \u00d7 ", ncol(df), " cols)")
      }, character(1))
      paste0("Available variables in your R script:\n", paste(lines, collapse = "\n"))
    } else if (!is.null(extra) && length(extra) == 1) {
      # Single uploaded file: show the variable name the user can reference
      nm  <- names(extra)[1]
      df  <- extra[[nm]]
      base <- paste0("Variable: ", nm, "\n",
                     nrow(df), " rows \u00d7 ", ncol(df), " cols\n",
                     "Columns: ", paste(names(df), collapse = ", "))
      if (!is.null(rv$sheet_names) && length(rv$sheet_names) > 1) {
        base <- paste0(length(rv$sheet_names), " sheets: ",
                       paste(rv$sheet_names, collapse = ", "), "\n", base)
      }
      base
    } else {
      req(rv$active_df)
      base <- paste0(nrow(rv$active_df), " rows \u00d7 ", ncol(rv$active_df), " cols\n",
                     "Columns: ", paste(names(rv$active_df), collapse = ", "))
      if (!is.null(rv$sheet_names) && length(rv$sheet_names) > 1) {
        base <- paste0(length(rv$sheet_names), " sheets: ",
                       paste(rv$sheet_names, collapse = ", "), "\n", base)
      }
      base
    }
  })

  # ====== shinychat: main conversation handler ======
  set_request_controls_busy <- function(busy) {
    request_in_flight(isTRUE(busy))
    control_ids <- c(
      "web_search_enabled", "dataset", "load_code_btn", "reset_plot",
      "undo_plot", "change_settings", "llm_provider", "save_config_btn",
      "csv_upload", "code_upload", "code_paste", "journal_upload"
    )
    for (id in control_ids) {
      if (isTRUE(busy)) shinyjs::disable(id) else shinyjs::enable(id)
    }
    if (!isTRUE(busy) && !web_search_supported(isolate(rv$provider))) {
      shinyjs::disable("web_search_enabled")
    }
  }

  display_chat_error <- function(error) {
    detail <- if (inherits(error, "condition")) conditionMessage(error) else as.character(error)
    showNotification(
      paste0("Chat error \u2014 ", detail,
             ". Check your provider settings and internet connection."),
      type = "error", duration = 10
    )
  }

  dispatch_chat_request <- function(text, append_user_message = FALSE) {
    text <- trimws(text %||% "")
    if (nchar(text) == 0L) return(invisible(FALSE))
    chat <- chat_obj()
    if (is.null(chat)) return(invisible(FALSE))
    if (isTRUE(request_in_flight())) {
      showNotification("Please wait for the current response to finish.", type = "warning")
      return(invisible(FALSE))
    }

    provider <- isolate(rv$provider)
    effective_search <- isTRUE(search_intent()) && web_search_supported(provider)
    expected_generation <- chat_generation()
    expected_plot <- isolate(rv$active_plot_name)

    guarded_update_plot <- function(code) {
      if (!identical(isolate(chat_obj()), chat) ||
          !identical(isolate(chat_generation()), expected_generation) ||
          !identical(isolate(rv$active_plot_name), expected_plot)) {
        return("Plot update rejected because the active plot or conversation changed. Please try again.")
      }
      update_plot_fn(code)
    }

    set_request_controls_busy(TRUE)
    request_promise <- tryCatch({
      update_plot_tool <- create_update_plot_tool(guarded_update_plot)
      chat$set_tools(build_request_tools(provider, update_plot_tool, effective_search))
      chat$set_system_prompt(with_search_guidance(chat$get_system_prompt(), effective_search))
      if (isTRUE(append_user_message)) {
        chat_append_message("chat", list(role = "user", content = text), chunk = FALSE)
      }
      current_warnings <- isolate(all_plot_warnings())
      model_text <- if (nrow(current_warnings)) {
        labels <- ifelse(current_warnings$important, "may affect the requested change", "routine")
        paste0(text, "\n\n(Warnings shown for the current plot: ",
               paste0(current_warnings$message, " [", labels, "]", collapse = "; "), ")")
      } else {
        text
      }
      chat_append(
        "chat",
        chat$stream_async(model_text, tool_mode = "sequential", stream = "content")
      )
    }, error = function(error) {
      display_chat_error(error)
      set_request_controls_busy(FALSE)
      NULL
    })

    if (is.null(request_promise)) return(invisible(FALSE))

    handled <- promises::catch(request_promise, function(error) {
      display_chat_error(error)
      NULL
    })
    promises::finally(handled, function() {
      set_request_controls_busy(FALSE)
    })
    invisible(TRUE)
  }

  observeEvent(input$chat_user_input, {
    req(chat_obj())
    req(nchar(trimws(input$chat_user_input)) > 0)
    dispatch_chat_request(input$chat_user_input)
  })

  # ====== Voice: background Web Speech API ======
  # speech.js fires voice_text when speech recognition finishes.
  # Show the spoken text as a user bubble, then stream the AI response —
  # same as what happens when the user types in the chat widget, but we
  # bypass the input box entirely (update_chat_user_input not available
  # in shinychat 0.2.x).
  last_voice_txt  <- ""
  last_voice_time <- Sys.time() - 100  # far in the past

  observeEvent(input$voice_text, {
    req(chat_obj())
    req(input$voice_text$text)
    txt <- trimws(input$voice_text$text)
    message("\n==================================")
    message("[VOICE RECEIVED] txt: ", txt)
    message("==================================\n")
    if (nchar(txt) == 0) return()
    # Guard: ignore if same text was processed within the last 2 seconds
    # (Chrome's onend can fire twice for a single utterance)
    now <- Sys.time()
    if (txt == last_voice_txt && as.numeric(now - last_voice_time) < 2) {
      message("[voice] Duplicate suppressed: ", txt)
      return()
    }
    last_voice_txt  <<- txt
    last_voice_time <<- now
    dispatch_chat_request(txt, append_user_message = TRUE)
  })

  # ====== Initial Code Upload / Paste ======
  observeEvent(input$load_code_btn, {
    code <- ""

    if (!is.null(input$code_upload)) {
      code <- tryCatch(
        paste(readLines(input$code_upload$datapath, warn = FALSE), collapse = "\n"),
        error = function(e) {
          rv$code_load_msg <- list(ok = FALSE,
                                   msg = paste("Could not read file:", conditionMessage(e)))
          ""
        }
      )
      if (nchar(trimws(code)) == 0 && !is.null(rv$code_load_msg) && !rv$code_load_msg$ok) return()
    }
    if (nchar(trimws(code)) == 0) {
      code <- trimws(input$code_paste)
    }
    if (nchar(code) == 0) {
      rv$code_load_msg <- list(ok = FALSE, msg = "Nothing to load — upload a file or paste code first.")
      return()
    }

    parse_result <- tryCatch({ parse(text = code); NULL }, error = function(e) conditionMessage(e))
    if (!is.null(parse_result)) {
      rv$code_load_msg <- list(ok = FALSE, msg = paste("Syntax error:", parse_result))
      return()
    }

    # Detect and install any packages required by the uploaded script
    script_pkgs <- extract_script_packages(code)
    if (length(script_pkgs) > 0) {
      missing_pkgs <- script_pkgs[!sapply(script_pkgs, requireNamespace, quietly = TRUE)]
      if (length(missing_pkgs) > 0) {
        rv$code_load_msg <- list(ok = TRUE, msg = paste0(
          "\u23f3 Installing: ", paste(missing_pkgs, collapse = ", "), "\u2026"
        ))
        pkg_result <- withProgress(
          message = paste0("Installing: ", paste(missing_pkgs, collapse = ", ")), {
            install_script_packages(script_pkgs)
          }
        )
        if (length(pkg_result$failed) > 0) {
          rv$code_load_msg <- list(ok = FALSE, msg = paste0(
            "Could not install: ", paste(pkg_result$failed, collapse = ", "),
            ". Run manually: install.packages(c(",
            paste0('"', pkg_result$failed, '"', collapse = ", "), "))"
          ))
          return()
        }
      }
    }

    # Evaluate to detect multiple plots
    extra <- c(list(user_data = isolate(rv$active_df), user_data_path = isolate(rv$user_data_path)),
               isolate(rv$extra_datasets))
    result <- eval_multi_plots(code, extra_vars = extra)
    rv$eval_warnings <- result$warnings %||% character()

    rv$code_history <- append(isolate(rv$code_history), list(list(code = rv$current_code, plot_name = isolate(rv$active_plot_name))))
    rv$current_code <- code
    rv$error_msg    <- NULL

    if (result$success && length(result$plots) > 1) {
      rv$multi_plots      <- result$plots
      rv$active_plot_name <- names(result$plots)[1]
      rv$current_plot     <- result$plots[[1]]
      # Populate all per-plot entries on initial script load
      for (nm in names(result$plots)) rv_single_plots[[nm]] <- result$plots[[nm]]
      # Split script into preamble + per-plot code blocks for LLM isolation
      split <- split_script(code, extra_vars = extra)
      if (!is.null(split)) {
        rv$preamble_code <- split$preamble
        rv$plot_codes    <- split$plot_codes
        message("[load_code] Script split: preamble=", nchar(split$preamble), " chars, ",
                length(split$plot_codes), " plot blocks")
      } else {
        rv$preamble_code <- NULL
        rv$plot_codes    <- NULL
      }
      .store_deps(split, names(result$plots)[1])
      rv$code_load_msg    <- list(ok = TRUE, msg = paste0(
        length(result$plots), " figures detected (", nchar(code), " chars) \u2014 select a figure above."
      ))
    } else if (result$success) {
      rv$multi_plots      <- NULL
      rv$active_plot_name <- names(result$plots)[1]
      rv$current_plot     <- result$plots[[1]]
      rv$preamble_code    <- NULL
      rv$plot_codes       <- NULL
      rv$plot_dep_contexts  <- NULL
      rv$preamble_deps_text <- NULL
      rv$code_load_msg    <- list(ok = TRUE, msg = paste0("Loaded (", nchar(code), " chars) \u2014 rendering plot\u2026"))
    } else {
      rv$multi_plots      <- NULL
      rv$active_plot_name <- NULL
      rv$current_plot     <- NULL
      rv$preamble_code    <- NULL
      rv$plot_codes       <- NULL
      rv$plot_dep_contexts  <- NULL
      rv$preamble_deps_text <- NULL
      rv$error_msg        <- result$error
      rv$code_load_msg    <- list(ok = FALSE, msg = paste0("Error: ", result$error))
      return()
    }

    # Clear the paste area only on successful load
    updateTextAreaInput(session, "code_paste", value = "")
    # Re-init chat so the LLM knows about the new starting code
    req(rv$configured)
    init_chat()
  })

  output$code_load_status <- renderUI({
    msg <- rv$code_load_msg
    if (is.null(msg)) return(NULL)
    if (msg$ok) {
      div(tags$i(class = "fa fa-check-circle", style = "color:#18BC9C;"),
          span(style = "font-size:0.85em;", paste0(" ", msg$msg)))
    } else {
      div(class = "error-msg",
          tags$i(class = "fa fa-exclamation-triangle"),
          paste0(" ", msg$msg))
    }
  })

  # ====== Journal Skills Upload ======
  observeEvent(input$journal_upload, {
    req(input$journal_upload)
    content <- tryCatch(
      paste(readLines(input$journal_upload$datapath, warn = FALSE), collapse = "\n"),
      error = function(e) {
        showNotification(
          paste("Could not read journal file:", conditionMessage(e)),
          type = "error", duration = 8
        )
        ""
      }
    )
    if (nchar(trimws(content)) == 0) return()
    rv$journal_instructions <- content

    # Notify JavaScript for visual feedback
    session$sendCustomMessage("update_journal_instructions", content)

    # Re-init chat so journal instructions are baked into the system prompt
    req(rv$configured)
    init_chat()
  })

  output$journal_status <- renderUI({
    if (is.null(rv$journal_instructions) || nchar(rv$journal_instructions) == 0) {
      span(style = "color:#8b949e; font-size:0.85em;", "No journal skills loaded")
    } else {
      div(
        tags$i(class = "fa fa-check-circle", style = "color:#2fa87e;"),
        span(style = "font-size:0.85em;",
             paste0(" Active (", nchar(rv$journal_instructions), " chars)"))
      )
    }
  })

  # ====== Thumbnail renderPlots (dynamic, one per detected plot) ======
  # The outer observe only re-runs when the SET OF PLOT NAMES changes (new script loaded).
  # Each renderPlot takes a reactive dependency on rv_single_plots[[pname]] only —
  # so clicking thumbnail of plot A and having the LLM modify plot A re-renders ONLY plot A.
  observe({
    plots <- rv$multi_plots
    if (is.null(plots) || length(plots) == 0) return()
    for (nm in names(plots)) {
      local({
        pname <- nm
        output[[paste0("thumb_", pname)]] <- renderPlot({
          rv_single_plots[[pname]]
        }, width = 240, height = 150)
      })
    }
  })

  # ====== Figures Panel UI (shown only when multiple plots exist) ======
  output$figures_panel_ui <- renderUI({
    plots <- rv$multi_plots
    if (is.null(plots) || length(plots) <= 1) return(NULL)
    # Isolate active_plot_name so thumbnail clicks don't re-render the whole panel
    active <- isolate(rv$active_plot_name) %||% names(plots)[1]

    thumb_items <- lapply(names(plots), function(nm) {
      is_active <- identical(nm, active)
      div(
        id              = paste0("thumb_wrap_", nm),
        class           = paste0("thumb-item", if (is_active) " active" else ""),
        "data-plotname" = nm,
        plotOutput(paste0("thumb_", nm), width = "100%", height = "160px"),
        div(class = "thumb-label", nm)
      )
    })

    bslib::card(
      style = "width:280px; flex-shrink:0; align-self:stretch;",
      bslib::card_header(
        style = "display:flex; justify-content:space-between; align-items:center; padding:8px 10px;",
        div(
          style = "font-size:0.82em; font-weight:600;",
          tags$i(class = "fa-solid fa-images"),
          " Figures"
        ),
        tags$span(
          class = "badge bg-success",
          style = "font-size:0.72em;",
          length(plots)
        )
      ),
      bslib::card_body(
        style = "padding:8px; overflow-y:auto;",
        div(class = "thumb-strip", thumb_items)
      )
    )
  })

  # ====== Handle thumbnail click ======
  observeEvent(input$selected_plot, {
    nm    <- input$selected_plot
    plots <- isolate(rv$multi_plots)
    req(!is.null(plots), nm %in% names(plots))
    if (isTRUE(request_in_flight())) {
      session$sendCustomMessage("updateActiveThumb", isolate(rv$active_plot_name))
      showNotification("Please wait for the current response to finish.", type = "warning")
      return()
    }
    # Guard: if already on this plot, skip redundant init_chat (priority:event fires on re-click)
    if (identical(nm, isolate(rv$active_plot_name))) return()
    rv$active_plot_name <- nm
    # Use rv_single_plots[[nm]] — always holds the latest edited version.
    # rv$multi_plots[[nm]] is frozen at script-load time and goes stale after LLM edits.
    rv$current_plot     <- isolate(rv_single_plots[[nm]]) %||% plots[[nm]]
    # Update active class via JS without re-rendering the whole panel
    session$sendCustomMessage("updateActiveThumb", nm)
    # Recompute preamble dep context for the newly selected plot before re-initialising chat
    .dep_ctxs <- isolate(rv$plot_dep_contexts)
    .pc       <- isolate(rv$plot_codes)
    if (!is.null(.dep_ctxs) && !is.null(.pc) && nm %in% names(.dep_ctxs)) {
      rv$preamble_deps_text <- extract_preamble_deps(.pc[[nm]], .dep_ctxs[[nm]])
    } else {
      rv$preamble_deps_text <- NULL
    }
    # Re-init chat so LLM context switches to the newly selected plot's code block.
    # clear_ui = FALSE preserves the visible conversation history — only the LLM
    # system prompt is refreshed with the new plot's code block.
    req(rv$configured)
    init_chat(clear_ui = FALSE)
  })

  # ====== Plot Rendering ======
  plot_eval_error <- reactiveVal(NULL)

  # Evaluated outside renderPlot: assigning rv$current_plot inside it re-invalidated the render mid-flight.
  observe({
    req(is.null(rv$current_plot))
    extra  <- c(list(user_data = rv$active_df, user_data_path = rv$user_data_path),
                isolate(rv$extra_datasets))
    result <- eval_multi_plots(rv$current_code, extra_vars = extra)
    rv$eval_warnings <- result$warnings %||% character()
    if (result$success) {
      active_name <- rv$active_plot_name %||% names(result$plots)[1]
      plot_eval_error(NULL)
      rv$current_plot <- result$plots[[active_name]] %||% result$plots[[1]]
    } else {
      plot_eval_error(result$error)
    }
  })

  output$main_plot <- renderPlot({
    p   <- rv$current_plot
    err <- plot_eval_error()
    req(!is.null(p) || !is.null(err))

    if (!is.null(p)) {
      message("[renderPlot] Printing stored plot. class: ", paste(class(p), collapse = ", "))
      # renderPlot never reads plot_warnings, so setting it here cannot re-trigger this render.
      tryCatch({
        plot_warnings(print_plot_with_warnings(p))
        plot_render_count(isolate(plot_render_count()) + 1L)
      }, error = function(e) {
        message("[renderPlot] ERROR during print(p): ", conditionMessage(e))
        message("[renderPlot] Call: ", deparse(conditionCall(e)))
        stop(e)
      })
    } else {
      plot_warnings(character())
      ggplot() +
        annotate("text", x = 0.5, y = 0.5,
                 label = paste("Plot Error:\n", err),
                 size = 5, color = "red", hjust = 0.5) +
        theme_void()
    }
  })

  # ====== Error Display ======
  observe({
    after <- warning_note_after()
    req(!is.null(after), !isTRUE(request_in_flight()), plot_render_count() > after)
    warning_note_after(NULL)
    warnings <- isolate(all_plot_warnings())
    warnings <- warnings[warnings$important, , drop = FALSE]
    if (nrow(warnings)) {
      chat_append_message("chat", list(role = "assistant", content = paste0(
        "⚠️ **Part of this change may not have been applied.** ggplot2 reported:\n\n",
        paste0("- ", htmltools::htmlEscape(warnings$note), " (", htmltools::htmlEscape(warnings$message), ")",
               collapse = "\n"),
        "\n\nCheck the plot, and ask me to fix it if it does not look right."
      )), chunk = FALSE)
    }
  })

  output$plot_error <- renderUI({
    warnings  <- all_plot_warnings()
    important <- warnings[warnings$important, , drop = FALSE]
    routine   <- warnings[!warnings$important, , drop = FALSE]
    warning_items <- function(rows) {
      tags$ul(lapply(seq_len(nrow(rows)), function(i) {
        tags$li(rows$note[i], tags$div(class = "warning-detail", rows$message[i]))
      }))
    }
    tagList(
      if (!is.null(rv$error_msg)) {
        div(class = "error-msg",
            tags$i(class = "fa fa-exclamation-triangle"),
            " ", rv$error_msg)
      },
      if (nrow(important)) {
        div(class = "warning-msg",
            tags$strong(tags$i(class = "fa fa-triangle-exclamation"),
                        " Part of the plot may not have been applied as requested."),
            warning_items(important))
      },
      if (nrow(routine)) {
        div(class = "warning-msg routine",
            tags$strong(tags$i(class = "fa fa-circle-info"), " Note (usually expected):"),
            warning_items(routine))
      }
    )
  })

  # ====== Code Display ======
  output$code_display <- renderText({ rv$current_code })

  # ====== Reset Plot ======
  observeEvent(input$reset_plot, {
    rv$code_history  <- append(isolate(rv$code_history), list(list(code = rv$current_code, plot_name = isolate(rv$active_plot_name))))
    rv$current_code     <- trimws(DEFAULT_PLOT_CODE)
    rv$current_plot     <- NULL
    rv$error_msg        <- NULL
    rv$preamble_code    <- NULL
    rv$plot_codes       <- NULL
    rv$plot_dep_contexts  <- NULL
    rv$preamble_deps_text <- NULL
    rv$extra_datasets   <- list()
    rv$multi_plots      <- NULL
    rv$active_plot_name <- NULL
    rv$active_df        <- mtcars
    rv$data_summary     <- summarize_dataframe(mtcars)
    skip_dataset_init_chat(TRUE)
    updateSelectInput(session, "dataset", selected = "mtcars")
    # Re-init so LLM sees reset code
    req(rv$configured)
    init_chat()
  })

  # ====== Undo ======
  observeEvent(input$undo_plot, {
    if (length(rv$code_history) > 0) {
      entry           <- rv$code_history[[length(rv$code_history)]]
      rv$code_history <- rv$code_history[-length(rv$code_history)]
      # Support both new format (list with code + plot_name) and legacy plain string
      if (is.list(entry)) {
        restored   <- entry$code
        saved_name <- entry$plot_name
      } else {
        restored   <- entry
        saved_name <- NULL
      }
      rv$current_code <- restored
      rv$current_plot <- NULL
      rv$error_msg    <- NULL
      # Re-evaluate the restored code to rebuild multi-plot state
      extra <- c(list(user_data = isolate(rv$active_df), user_data_path = isolate(rv$user_data_path)),
                 isolate(rv$extra_datasets))
      result <- eval_multi_plots(restored, extra_vars = extra)
      rv$eval_warnings <- result$warnings %||% character()
      if (result$success && length(result$plots) > 1) {
        rv$multi_plots <- result$plots
        # Sync rv_single_plots for every plot so tab-switching after undo shows
        # the correct (restored) version rather than the stale pre-undo version.
        for (nm in names(result$plots)) rv_single_plots[[nm]] <- result$plots[[nm]]
        # Restore the active plot that was in focus when this snapshot was taken
        restored_name <- if (!is.null(saved_name) && saved_name %in% names(result$plots)) {
          saved_name
        } else {
          names(result$plots)[1]
        }
        rv$active_plot_name <- restored_name
        rv$current_plot     <- result$plots[[restored_name]]
        split <- split_script(restored, extra_vars = extra)
        if (!is.null(split)) {
          rv$preamble_code <- split$preamble
          rv$plot_codes    <- split$plot_codes
        } else {
          rv$preamble_code <- NULL
          rv$plot_codes    <- NULL
        }
        .store_deps(split, restored_name)
      } else {
        rv$multi_plots      <- NULL
        rv$active_plot_name <- if (result$success) names(result$plots)[1] else NULL
        rv$current_plot     <- if (result$success) result$plots[[1]] else NULL
        rv$preamble_code      <- NULL
        rv$plot_codes         <- NULL
        rv$plot_dep_contexts  <- NULL
        rv$preamble_deps_text <- NULL
        # Surface restore failures explicitly — the handler clears rv$error_msg at the
        # top so without this the user would see a blank error panel on a failed undo.
        if (!result$success) {
          rv$error_msg <- paste("Undo restore error:", result$error)
        }
      }
      # Recreate the chat session aligned to the restored code.
      # Without this the LLM carries stale conversation turns from the undone edit
      # and can fold them back into the user's next instruction.
      # clear_ui = TRUE (default): clearing chat bubbles is honest — the user undid
      # those changes, so showing the prior exchange would be misleading.
      if (isTRUE(rv$configured)) init_chat()
    } else {
      showNotification("Nothing to undo — no previous versions saved.", type = "warning", duration = 3)
    }
  })

  # ====== Copy Code to Clipboard ======
  observeEvent(input$copy_code, {
    session$sendCustomMessage("copy_to_clipboard", rv$current_code)
  })

  # ====== Export Plot ======
  # Disable the export button when there is no rendered plot
  observe({
    if (is.null(rv$current_plot)) {
      shinyjs::disable("export_plot_btn")
    } else {
      shinyjs::enable("export_plot_btn")
    }
  })

  output$export_plot_btn <- downloadHandler(
    filename = function() {
      paste0("ggplot_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".", input$export_format)
    },
    content = function(file) {
      if (is.null(isolate(rv$current_plot))) {
        showNotification("No plot to export yet \u2014 render a plot first.",
                         type = "warning", duration = 4)
        return()
      }
      tmp <- export_plot(
        plot_obj  = isolate(rv$current_plot),
        format    = input$export_format,
        width_in  = input$export_width,
        height_in = input$export_height,
        dpi       = input$export_dpi
      )
      if (!is.null(tmp)) {
        file.copy(tmp, file)
        unlink(tmp)
      } else {
        showNotification("Export failed \u2014 check plot dimensions and try again.",
                         type = "error", duration = 5)
      }
    }
  )

  # ====== Download Script-Prep Prompt ======
  output$download_prep_prompt <- downloadHandler(
    filename = function() "ggplot_voice_copilot_script_prep_prompt.txt",
    content  = function(file) writeLines(SCRIPT_PREP_PROMPT, file)
  )
}
