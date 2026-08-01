# ui.R — Shiny UI for ggplot Voice Copilot (conversational AI edition)
# -----------------------------------------------------------------------
# Key differences from ellmer-win edition:
#   • Voice button, manual text box, and stream display are REMOVED from
#     the sidebar — shinychat::chat_ui() replaces them all.
#   • Voice still works in the background: Web Speech API fires voice_text,
#     and the server calls update_chat_user_input() to auto-submit it.
#   • Command history panel is removed — the chat IS the history.
#   • Press Space (when not typing) to toggle voice recognition.
# -----------------------------------------------------------------------

ui <- tagList(
  # ── First-run setup overlay (fixed-position, z-index 9999) ──
  conditionalPanel(
    condition = "output.setup_mode",
    div(
      class = "setup-overlay",
      div(
        class = "setup-card",
        style = "max-width:520px;",
        tags$i(class = "fa-solid fa-chart-line", style = "font-size:2.5em; color:#18BC9C;"),
        h2("GeomWhisper", style = "margin:10px 0 4px; font-family:'Barlow Condensed',sans-serif; font-weight:700; letter-spacing:0.06em; background:linear-gradient(90deg,#E8B068,#C8541A); -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;"),
        p("Multi-LLM Edition", style = "color:#7f8c8d; margin-bottom:24px;"),
        hr(),

        # ── Provider selector ──
        h5(tags$i(class = "fa-solid fa-robot"), " AI Provider"),
        selectInput("llm_provider", label = NULL,
                    choices = c(
                      "OpenAI"                 = "openai",
                      "Anthropic (Claude)"     = "anthropic",
                      "Google Gemini"          = "google",
                      "Ollama (local, free)"   = "ollama"
                    ),
                    selected = "openai", width = "100%"),

        # ── Model selector ── one conditionalPanel per provider ──
        conditionalPanel(
          condition = "input.llm_provider == 'openai'",
          textInput("model_openai", "Model", value = "gpt-4o",
                    placeholder = "e.g. gpt-4o, gpt-4o-mini, gpt-4.1-mini, o1, o3-mini",
                    width = "100%")
        ),
        conditionalPanel(
          condition = "input.llm_provider == 'anthropic'",
          textInput("model_anthropic", "Model", value = "claude-3-5-sonnet-20241022",
                    placeholder = "e.g. claude-opus-4-5, claude-3-5-sonnet-20241022",
                    width = "100%")
        ),
        conditionalPanel(
          condition = "input.llm_provider == 'google'",
          textInput("model_google", "Model", value = "gemini-2.0-flash",
                    placeholder = "e.g. gemini-2.0-flash, gemini-1.5-pro",
                    width = "100%")
        ),
        conditionalPanel(
          condition = "input.llm_provider == 'ollama'",
          textInput("model_ollama", "Model name", value = "llama3.1",
                    placeholder = "e.g. llama3.1, mistral, phi4, qwen2.5",
                    width = "100%")
        ),

        # ── API key — one panel per provider with proper label/placeholder/link ──

        # OpenAI
        conditionalPanel(
          condition = "input.llm_provider == 'openai'",
          h5(tags$i(class = "fa-solid fa-key"), " OpenAI API Key"),
          passwordInput("api_key_openai", label = NULL,
                        placeholder = "sk-\u2026", width = "100%"),
          div(style = "margin-bottom:12px; font-size:0.85em;",
              tags$a(href = "https://platform.openai.com/api-keys", target = "_blank",
                tags$i(class = "fa-solid fa-arrow-up-right-from-square"),
                " Get your key at platform.openai.com/api-keys"))
        ),

        # Anthropic
        conditionalPanel(
          condition = "input.llm_provider == 'anthropic'",
          h5(tags$i(class = "fa-solid fa-key"), " Anthropic API Key"),
          passwordInput("api_key_anthropic", label = NULL,
                        placeholder = "sk-ant-\u2026", width = "100%"),
          div(style = "margin-bottom:12px; font-size:0.85em;",
              tags$a(href = "https://console.anthropic.com/settings/keys", target = "_blank",
                tags$i(class = "fa-solid fa-arrow-up-right-from-square"),
                " Get your key at console.anthropic.com/settings/keys"))
        ),

        # Google Gemini
        conditionalPanel(
          condition = "input.llm_provider == 'google'",
          h5(tags$i(class = "fa-solid fa-key"), " Google AI API Key"),
          passwordInput("api_key_google", label = NULL,
                        placeholder = "AIza\u2026", width = "100%"),
          div(style = "margin-bottom:12px; font-size:0.85em;",
              tags$a(href = "https://aistudio.google.com/app/apikey", target = "_blank",
                tags$i(class = "fa-solid fa-arrow-up-right-from-square"),
                " Get your key at aistudio.google.com/app/apikey"))
        ),

        # Ollama — no key needed
        conditionalPanel(
          condition = "input.llm_provider == 'ollama'",
          div(style = "margin-bottom:12px; font-size:0.88em; color:#7f8c8d; background:#f4f4f4; border-radius:5px; padding:8px 10px;",
              tags$i(class = "fa-solid fa-circle-info"),
              " No API key needed. Make sure Ollama is running locally (",
              tags$code("ollama serve"), ")."
          )
        ),

        uiOutput("setup_error_msg"),

        actionButton("save_config_btn", "Save & Continue", icon = icon("arrow-right"),
                     class = "btn btn-success btn-lg w-100")
      )
    )
  ),

  # ── Main app ──
  bslib::page_sidebar(
    title = tagList(
      tags$span(
        tags$i(class = "fa-solid fa-waveform-lines", style = "color:#C8541A;"),
        tags$span(
          "GeomWhisper",
          style = paste0(
            "font-family:'Barlow Condensed',sans-serif;",
            "font-weight:700; font-size:1.25em; letter-spacing:0.08em;",
            "background:linear-gradient(90deg,#E8B068 0%,#C8541A 60%);",
            "-webkit-background-clip:text; -webkit-text-fill-color:transparent;",
            "background-clip:text; margin-left:7px;"
          )
        )
      ),

      actionButton("show_authors", NULL,
                   icon  = icon("users"),
                   title = "About the Authors",
                   class = "btn-sm btn-outline-light",
                   style = "margin-left:14px; padding:2px 8px;")
    ),
    theme = bslib::bs_theme(
      bootswatch   = "flatly",
      base_font    = bslib::font_google("Inter"),
      heading_font = bslib::font_google("Inter"),
      primary      = "#C8541A",
      success      = "#5B6426"
    ) |> bslib::bs_add_rules("
      /* ── Call of Duty (Tactical) Theme ── */
      body, .bslib-page-sidebar { background-color: #0F100D !important; }
      /* Sidebar */
      .bslib-sidebar-layout > .sidebar {
        background-color: #0C0E0A !important;
        border-right: 2px solid rgba(200,84,26,0.45) !important;
      }
      .bslib-sidebar-layout > .sidebar,
      .bslib-sidebar-layout > .sidebar label,
      .bslib-sidebar-layout > .sidebar .form-label,
      .bslib-sidebar-layout > .sidebar p {
        color: #C4BFB5 !important;
      }
      .bslib-sidebar-layout > .sidebar h6 {
        color: #C8541A !important;
        font-family: 'Barlow Condensed', sans-serif;
        text-transform: uppercase;
        letter-spacing: 0.10em;
        font-size: 0.72em;
        font-weight: 700;
        border-left: 3px solid #C8541A;
        padding-left: 8px;
        margin-top: 6px;
      }
      .bslib-sidebar-layout > .sidebar hr {
        border-color: rgba(200,84,26,0.20) !important;
      }
      .bslib-sidebar-layout > .sidebar .form-control,
      .bslib-sidebar-layout > .sidebar .form-select,
      .bslib-sidebar-layout > .sidebar textarea {
        background-color: #1A1C18 !important;
        border-color: rgba(200,84,26,0.28) !important;
        color: #C4BFB5 !important;
      }
      .bslib-sidebar-layout > .sidebar .form-control:focus,
      .bslib-sidebar-layout > .sidebar .form-select:focus {
        border-color: #C8541A !important;
        box-shadow: 0 0 0 2px rgba(200,84,26,0.20) !important;
      }
      .bslib-sidebar-layout > .sidebar .shiny-text-output {
        background: #1A1C18 !important;
        color: #E8B068 !important;
      }
      .voice-hint {
        background-color: rgba(200,84,26,0.07) !important;
        border: 1.5px solid rgba(200,84,26,0.38) !important;
        color: #E8B068 !important;
      }
      .voice-hint kbd { background: rgba(200,84,26,0.72) !important; }
      .navbar {
        background: linear-gradient(90deg, #080908 0%, #181A14 100%) !important;
        border-bottom: 2px solid #C8541A !important;
      }
      .card {
        background: #161814 !important;
        border-left: 3px solid #C8541A !important;
        border-top-color: rgba(200,84,26,0.18) !important;
        border-right-color: rgba(200,84,26,0.18) !important;
        border-bottom-color: rgba(200,84,26,0.18) !important;
        transition: box-shadow 0.22s;
      }
      .card:hover {
        box-shadow: 0 0 0 2px rgba(200,84,26,0.22), 0 4px 18px rgba(0,0,0,0.4) !important;
      }
      .card-header {
        background: #0C0E0A !important;
        color: #C4BFB5 !important;
        border-bottom: 1px solid rgba(200,84,26,0.22) !important;
        font-family: 'Barlow Condensed', sans-serif;
        letter-spacing: 0.06em;
      }
      .card-body { background: #161814 !important; color: #C4BFB5 !important; }
      .btn { border-radius: 2px !important; }
      .thumb-item.active {
        background: #161814 !important;
        border-color: #C8541A !important;
        color: #E8B068 !important;
      }
      /* Accordion: tactical style */
      .bslib-sidebar-layout > .sidebar .accordion-item {
        background: transparent !important;
        border: none !important;
        border-bottom: 1px solid rgba(200,84,26,0.15) !important;
      }
      .bslib-sidebar-layout > .sidebar .accordion-button {
        background: transparent !important;
        color: #C4BFB5 !important;
        font-family: 'Barlow Condensed', sans-serif !important;
        font-size: 13px !important;
        font-weight: 600 !important;
        letter-spacing: 0.05em !important;
        text-transform: none !important;
        padding: 9px 4px !important;
        box-shadow: none !important;
      }
      .bslib-sidebar-layout > .sidebar .accordion-button:not(.collapsed) {
        color: #C8541A !important;
        background: rgba(200,84,26,0.07) !important;
      }
      .bslib-sidebar-layout > .sidebar .accordion-button::after {
        filter: brightness(0) saturate(100%) invert(42%) sepia(55%) saturate(700%) hue-rotate(350deg) brightness(90%) contrast(90%);
      }
      .bslib-sidebar-layout > .sidebar .accordion-body {
        padding: 6px 2px 12px !important;
      }
    "),


    tags$head(
      tags$link(rel = "stylesheet", href = "styles.css?v=5"),
      tags$link(
        rel  = "stylesheet",
        href = "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.0/css/all.min.css"
      ),
      tags$link(
        rel  = "stylesheet",
        href = "https://fonts.googleapis.com/css2?family=Dancing+Script:wght@700&family=Barlow+Condensed:wght@400;600;700&display=swap"
      )
    ),
    useShinyjs(),

    # ── Sidebar ──
    sidebar = bslib::sidebar(
      width = 360,
      open  = TRUE,

      # Model badge + change-settings
      div(
        style = "display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;",
        div(class = "agent-badge online",
            tags$i(class = "fa fa-circle", style = "font-size:0.6em;"),
            " ",
            uiOutput("model_badge", inline = TRUE)),
        actionButton("change_settings", NULL, icon = icon("gears"), title = "Change AI Settings",
                     class = "btn-sm btn-outline-secondary")
      ),

      # Voice hint (no visible button — spacebar triggers it)
      div(
        id    = "voice_hint",
        class = "voice-hint",
        tags$i(class = "fa fa-microphone", style = "color:#18BC9C;"),
        " Press ",
        tags$kbd("Space"),
        " to speak — voice is sent to the chat"
      ),
      div(id = "voice_interim", class = "voice-interim", style = "display:none;"),

      bslib::accordion(
        id       = "sidebar_acc",
        multiple = TRUE,
        open     = c("chat", "dataset"),

        # ── Chat ──────────────────────────────────────────────────
        bslib::accordion_panel(
          title = tagList(tags$i(class = "fa-solid fa-comments"), " Chat with Plot"),
          value = "chat",
          shinychat::chat_ui("chat", height = "340px",
                             placeholder = "Ask about the plot or request a change\u2026")
        ),

        # ── Dataset ───────────────────────────────────────────────
        bslib::accordion_panel(
          title = tagList(tags$i(class = "fa-solid fa-database"), " Dataset"),
          value = "dataset",
          selectInput("dataset", label = NULL,
                      choices  = c("mtcars", "Upload File…"),
                      selected = "mtcars"),
          conditionalPanel(
            condition = "input.dataset == 'Upload File\u2026'",
            fileInput("csv_upload", NULL, accept = ".csv,.xlsx,.xls,.rds",
                      multiple = TRUE,
                      placeholder = "CSV, XLSX, XLS or RDS (multiple allowed)"),
            p(style = "font-size:0.78em; color:#7f8c8d; margin:2px 0 0;",
              "Hold ", tags$kbd("Ctrl"), " to select multiple files. ",
              "Variable names shown below after upload.")
          ),
          verbatimTextOutput("data_info")
        ),

        # ── Initial Plot Code ──────────────────────────────────────
        bslib::accordion_panel(
          title = tagList(tags$i(class = "fa-solid fa-file-code"), " Initial Plot Code"),
          value = "code",
          p(style = "font-size:0.82em; color:#7f8c8d; margin-bottom:4px;",
            "Upload an .R file or paste ggplot2 code. The conversation will restart with this code as context."),
          div(
            style = "font-size:0.80em; background:#eaf4f2; border:1px solid #c8e6e2; border-radius:5px; padding:6px 10px; margin-bottom:6px;",
            tags$p(
              style = "margin:0 0 4px;",
              tags$i(class = "fa fa-circle-info", style = "color:#18BC9C;"),
              " Assign to ", tags$code("p"),
              " (e.g. ", tags$code("p <- ggplot(...)"), ") or end with a bare ", tags$code("ggplot(...)"), " call.",
              " Multiple plots are supported — each ggplot variable becomes a selectable figure."
            ),
            tags$p(
              style = "margin:0 0 4px;",
              tags$i(class = "fa fa-database", style = "color:#18BC9C;"),
              " Uploaded CSV/XLSX is always named ", tags$code("user_data"),
              " — e.g. ", tags$code("ggplot(user_data, aes(...))")
            ),
            tags$p(
              style = "margin:0;",
              tags$i(class = "fa fa-file-excel", style = "color:#18BC9C;"),
              " Multi-sheet Excel: use ",
              tags$code("read_excel(user_data_path, sheet = \"SheetName\")"),
              " to access other sheets."
            )
          ),
          fileInput("code_upload", label = NULL,
                    buttonLabel = tags$span(tags$i(class = "fa fa-upload"), " Browse .R"),
                    accept = ".R"),
          textAreaInput("code_paste", label = NULL,
                        placeholder = "\u2026or paste ggplot2 code here",
                        rows = 4, width = "100%"),
          actionButton("load_code_btn", tagList(tags$i(class = "fa fa-check"), " Load Code"),
                       class = "btn btn-success btn-sm w-100",
                       style = "margin-bottom:4px;"),
          uiOutput("code_load_status"),
          div(
            style = "margin-top:6px;",
            downloadButton(
              "download_prep_prompt",
              label = tagList(tags$i(class = "fa fa-wand-magic-sparkles"), " Download Script-Prep Prompt"),
              class = "btn btn-outline-secondary btn-sm w-100"
            ),
            p(style = "font-size:0.78em; color:#8b949e; margin-top:4px; margin-bottom:0;",
              "Paste this into any AI (ChatGPT, Claude, Gemini\u2026) to reformat your R script for use in this app.")
          )
        ),

        # ── Journal Skills ─────────────────────────────────────────
        bslib::accordion_panel(
          title = tagList(tags$i(class = "fa-solid fa-book"), " Journal Skills"),
          value = "journal",
          p(style = "font-size:0.82em; color:#8b949e; margin-bottom:4px;",
            "Upload a .md file to inject journal-specific requirements into every AI response."),
          fileInput("journal_upload", label = NULL,
                    buttonLabel = tags$span(tags$i(class = "fa fa-upload"), " Browse"),
                    accept = ".md"),
          uiOutput("journal_status")
        ),

        # ── Export Plot ────────────────────────────────────────────
        bslib::accordion_panel(
          title = tagList(tags$i(class = "fa-solid fa-download"), " Export Plot"),
          value = "export",
          selectInput("export_format", label = NULL,
                      choices  = c("PNG" = "png", "PDF" = "pdf", "SVG" = "svg"),
                      selected = "png"),
          fluidRow(
            column(6, numericInput("export_width",  "Width (in)",  value = 8, min = 2, max = 24, step = 0.5)),
            column(6, numericInput("export_height", "Height (in)", value = 6, min = 2, max = 24, step = 0.5))
          ),
          sliderInput("export_dpi", "DPI", min = 72, max = 600, value = 300, step = 12),
          downloadButton("export_plot_btn", label = tagList(tags$i(class = "fa fa-download"), " Export"),
                         class = "btn-outline-secondary w-100")
        )
      )
    ),

    # ── Main panel ──
    div(
      style = "display:flex; gap:10px; align-items:flex-start;",
      bslib::card(
        style = "flex:1; min-width:0;",
        bslib::card_header(
          style = "display:flex; justify-content:space-between; align-items:center;",
          div(tags$i(class = "fa-solid fa-chart-line"), " Plot Preview"),
          div(
            style = "display:flex; gap:6px;",
            actionButton("reset_plot", NULL, icon = icon("rotate-left"),
                         title = "Reset to default", class = "btn-sm btn-outline-secondary"),
            actionButton("undo_plot",  NULL, icon = icon("arrow-left"),
                         title = "Undo last change", class = "btn-sm btn-outline-secondary")
          )
        ),
        bslib::card_body(
          uiOutput("plot_error"),
          plotOutput("main_plot", height = "460px")
        )
      ),
      uiOutput("figures_panel_ui")
    ),

    tags$script(src = "speech.js")
  )
)
