# GeomWhisper

GeomWhisper is a locally runnable Shiny application for conversational and
voice-driven ggplot2 refinement powered by your choice of LLM provider.

Voice-controlled ggplot2 modification is powered by your choice of LLM provider
- OpenAI, Anthropic, Google Gemini, or a local Ollama model.

## First Look

![GeomWhisper showing the Dataset file picker and Initial Plot Code R-script picker.](images/geomwhisper-upload-workflow.png)

Start a project by choosing **Upload File...** in **Dataset** and uploading your
CSV, XLSX, XLS, or RDS data. Then upload an `.R` script in **Initial Plot Code**
or paste ggplot2 code before asking GeomWhisper to refine the visualization.

## Architecture

```
Browser (Shiny UI)
  └─ Web Speech API (JS)       ← free, no API key, Chrome/Edge only
       │ voice transcript
       ▼
  Shiny Server (R)
       │ ellmer (R package)
       ▼
  LLM Provider API              ← OpenAI / Anthropic / Google Gemini / Ollama
       │ tool call → R code
       ▼
  eval() → renderPlot() → back to browser
```

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| **R** | ≥ 4.4 | https://cran.r-project.org |
| **Chrome or Edge** | Latest | Required for Web Speech API |
| **API key** | Provider-specific | See [Choose your LLM provider](#2-choose-your-llm-provider) below |

## Quick Start

### 1. Installation

**Windows:** Run the installer (`setup_ggplot Voice Copilot (Multi-LLM).exe`)
- Automatically installs the latest R from CRAN if needed (R 4.4+ required)
- Auto-installs all required R packages

**Manual installation:** R packages are auto-installed on first startup

### 2. Choose your LLM provider

When you launch the app, select one:
- **OpenAI** — Requires: [API key](https://platform.openai.com/api-keys)
- **Anthropic** — Requires: [API key](https://console.anthropic.com)
- **Google Gemini** — Requires: [API key](https://aistudio.google.com/apikey)
- **Ollama** — Requires: [Ollama running locally](https://ollama.ai) (`ollama serve`)

### 3. Run

**Windows:**
```cmd
start.bat
```

**Manual (any OS):**
```bash
Rscript -e "shiny::runApp('.', port = 7475, host = '127.0.0.1', launch.browser = TRUE)"
```

Open **http://127.0.0.1:7475** in Chrome or Edge.

## Usage

1. Press the **Space bar** to begin voice input. When recognition finishes, your
     spoken command is sent to the chat automatically. Voice controls work in Chrome
     or Edge when the cursor is not in a text field.

2. Or **type a command** in the chat box and click Send.

3. The plot updates in real time. Use **Undo** to revert and **Reset** to return
     to the default plot.

## Rate Limits

Each provider has different rate limits:
- **OpenAI**: See [pricing](https://openai.com/pricing)
- **Anthropic**: See [pricing](https://www.anthropic.com/pricing)
- **Google Gemini**: Free tier available
- **Ollama**: Unlimited (runs locally)

## Reviewer-Friendly Verification

Run the offline smoke test:

```bash
Rscript tests/offline_smoke.R
```

This check validates core local helpers without requiring live API keys.

## Support and Contribution

- Contribution guidance is in `CONTRIBUTING.md`.
- The software citation metadata is in `CITATION.cff`.
- The JOSS manuscript scaffold is in `paper/paper.md` with references in `paper/paper.bib`.
- The repository is licensed under GPL-3.0; see `LICENSE`.
- Once the repository is public, issues and support requests should go through
     the public issue tracker.

## Project Structure

```
repo/
├── .github/
│   └── workflows/
│       ├── draft-pdf.yml        # JOSS draft PDF build
│       └── r-review-checks.yml  # Offline CI smoke test
├── paper/
│   ├── images/
│   │   └── geomwhisper_screenshot.png  # Figure for manuscript
│   ├── paper.bib             # JOSS bibliography
│   └── paper.md              # JOSS manuscript draft
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
