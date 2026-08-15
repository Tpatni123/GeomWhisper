# GeomWhisper

GeomWhisper is a locally runnable Shiny application for conversational and
voice-driven `ggplot2` refinement. It supports OpenAI, Anthropic, Google
Gemini, and local Ollama models.

## First Look

![GeomWhisper showing the Dataset file picker and Initial Plot Code R-script picker.](images/geomwhisper-upload-workflow.png)

Start a project by choosing **Upload File...** in **Dataset** and uploading one
or more CSV, XLSX, XLS, or RDS files. The first file is available as `user_data`;
each uploaded file is also available under a valid R variable name derived from
its filename and shown in the Dataset panel. Then upload an `.R` script in
**Initial Plot Code** or paste ggplot2 code before asking GeomWhisper to refine
the visualization.

## Architecture

```
Browser (Shiny UI)
  └─ Web Speech API (JS)       ← optional voice input; Chrome/Edge support
       │ voice transcript
       ▼
  Shiny Server (R)
       │ ellmer (R package)
       ▼
  LLM provider                   ← OpenAI / Anthropic / Google Gemini / Ollama
       │ tool call → R code
       ▼
  eval() → renderPlot() → back to browser
```

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| **R** | ≥ 4.4 | https://cran.r-project.org |
| **Chrome or Edge** | Latest | Required only for voice input; typed chat works without voice support |
| **API key** | Cloud providers only | Required for OpenAI, Anthropic, or Google Gemini |
| **Ollama** | Latest | Required only when using a local Ollama model |

## Quick Start

### 1. Installation

**Windows:** Run [GeomWhisper-Setup-1.0.0.exe](installer/GeomWhisper-Setup-1.0.0.exe).

- Detects installed R versions. GeomWhisper requires R 4.4 or later.
- Installs missing R packages on first launch. Internet access is required when
     packages are missing.

**Manual installation:** Install R 4.4 or later. The app installs its missing
R packages on first startup when an internet connection is available.

### 2. Choose your LLM provider

When you launch the app, select one:
- **OpenAI** — Requires: [API key](https://platform.openai.com/api-keys)
- **Anthropic** — Requires: [API key](https://console.anthropic.com/settings/keys)
- **Google Gemini** — Requires: [API key](https://aistudio.google.com/app/apikey)
- **Ollama** — Requires [Ollama](https://ollama.ai) running locally and the
     selected model installed, for example `ollama pull llama3.1` followed by
     `ollama serve`.

### 3. Run

**Windows:**
```cmd
start.bat
```

**Manual (any OS, from the project root):**
```bash
Rscript -e "shiny::runApp('.', port = 7475, host = '127.0.0.1', launch.browser = TRUE)"
```

Open **http://127.0.0.1:7475**. Chrome or Edge is required only for voice
input; use any supported browser for typed chat.

## Prepare an Existing R Script

Use the **Download Script-Prep Prompt** button in **Initial Plot Code** when
you have an existing R script that needs to be adapted for GeomWhisper. Paste
the downloaded prompt and your script into an AI assistant you trust, then
review the returned script before uploading or pasting it into the app.

The prompt asks the assistant to make the script compatible with GeomWhisper:

- replace file-loading code and hardcoded paths with the uploaded-data variables;
- use `user_data` for the first uploaded dataset and the variable names shown
     in the Dataset panel for additional datasets;
- assign a single plot to `p`, or use descriptive names for multiple plot
     objects;
- remove interactive display and export calls such as `print()`, `ggsave()`,
     `pdf()`, `png()`, and `dev.off()`.

This helper prepares code; it does not validate that an AI-generated analysis
is statistically correct. Inspect the result, test it on appropriate data, and
do not paste patient-level data, secrets, or other sensitive content into an
external AI service unless that use is approved for your environment.

## Data and Plot Code

- Uploads are limited to 50 MB. You can upload multiple CSV, XLSX, XLS, or RDS
     files in one selection.
- Excel files load their first sheet by default. For additional sheets in the
     first uploaded Excel file, use
     `readxl::read_excel(user_data_path, sheet = "SheetName")` in plot code.
- A single plot script must assign a `ggplot` object to `p` or end with a bare
     `ggplot(...)` expression. Scripts may define multiple plot objects; `p` is
     listed first and the remaining figures are selectable by name.
- Export the active plot as PNG, PDF, or SVG from the **Export Plot** panel.
- Upload a Markdown file in **Journal Skills** to include figure-style
     requirements in each model request.

## Usage

1. Press the **Space bar** to start or stop voice input. When recognition
     finishes, the transcript is sent to chat automatically. Voice controls work
     in Chrome or Edge when the cursor is not in a text field.

2. Or **type a command** in the chat box and click Send.

3. The plot updates in real time. Use **Undo** to revert and **Reset** to return
     to the default plot.

## Local Settings and Code Execution

Provider settings, including API keys and model selections, are saved as JSON in
the R user configuration directory so they can be restored on the next launch.
The file is not encrypted; use an operating-system account you trust and revoke
or rotate keys that may have been exposed.

The app evaluates uploaded and model-generated R code in its local R process to
render plots. Only upload scripts and use model providers that you trust.

## Rate Limits

Provider pricing and quotas change over time. Consult the current provider
documentation for [OpenAI](https://openai.com/pricing),
[Anthropic](https://www.anthropic.com/pricing), and
[Google Gemini](https://ai.google.dev/gemini-api/docs/pricing). Ollama has no
hosted-provider quota, but local capacity depends on the selected model and
your hardware.

## Reviewer-Friendly Verification

Run the offline smoke test:

```bash
Rscript tests/offline_smoke.R
```

This check verifies local helper functions and safe evaluation of valid and
invalid `ggplot2` code without requiring live API keys. It does not start the
Shiny interface, record speech, or call an LLM provider.

## Support and Contribution

- Contribution guidance is in [CONTRIBUTING.md](CONTRIBUTING.md).
- The software citation metadata is in [CITATION.cff](CITATION.cff).
- The compact JOSS manuscript source is
     [paper/paper-compact.md](paper/paper-compact.md), with references in
     [paper/paper.bib](paper/paper.bib) and a rendered preview in
     [paper/paper-compact.html](paper/paper-compact.html).
- The repository is licensed under GPL-3.0; see [LICENSE](LICENSE).
- Report bugs, feature requests, and support questions through the public issue
     tracker.

## Project Structure

```
repo/
├── .github/
│   └── workflows/
│       ├── draft-pdf.yml        # JOSS draft PDF build
│       └── r-review-checks.yml  # Offline CI smoke test
├── paper/
│   ├── images/
│   │   └── geomwhisper_*.png         # Compact manuscript figures
│   ├── paper-compact.md               # JOSS manuscript source
│   ├── paper-compact.html             # Rendered manuscript preview
│   ├── paper-compact_files/           # HTML preview assets
│   └── paper.bib                      # Manuscript bibliography
├── installer/
│   └── GeomWhisper-Setup-1.0.0.exe    # Windows installer
├── www/
│   ├── speech.js         # Browser Web Speech API integration
│   └── styles.css        # UI styles
├── tests/
│   └── offline_smoke.R   # Offline helper verification
├── skills/
│   ├── apa.md            # APA journal style skill
│   └── nature.md         # Nature journal style skill
├── CITATION.cff          # Software citation metadata
├── CONTRIBUTING.md       # Contribution and support guidance
├── global.R              # Shared config, chat creation, tool definitions
├── LICENSE               # GPL-3.0 license
├── ui.R                  # Shiny UI
├── server.R              # Shiny server
├── launch.ps1            # Windows PowerShell launcher (R detection, package install)
├── start.bat             # Windows launcher entry point
└── README.md
```
