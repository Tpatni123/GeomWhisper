# Contributing to GeomWhisper

GeomWhisper is an R/Shiny application for conversational and voice-driven
ggplot refinement. Contributions that improve reproducibility, usability,
documentation, and reviewer testability are especially valuable.

## Ways to Contribute

- Report bugs with a short reproduction, expected behavior, and actual behavior.
- Suggest research-facing workflow improvements for plot creation, editing, or
  review.
- Improve documentation, examples, and reviewer setup instructions.
- Add or strengthen offline verification scripts and automated checks.

## Before You Change Code

- Prefer focused changes over broad rewrites.
- Preserve the current local-first workflow: the app should still run through
  `start.bat` on Windows and through `shiny::runApp()` in R.
- Keep typed interaction working even when browser voice support is unavailable.
- Avoid introducing dependencies that make reviewer setup materially harder.

## Local Setup

### Windows launcher

Run:

```bat
start.bat
```

### Direct R launch

Run:

```r
shiny::runApp('.', port = 7475, host = '127.0.0.1', launch.browser = TRUE)
```

The launcher and app bootstrap will install missing R packages on first start.

## Current Verification Scripts

Until the repository is migrated to a formal automated test layout, use the
existing scripts as targeted smoke checks:

- `simple_test.R`
- `test_real_tool_error.R`
- `test_shinychat_with_tool.R`
- `test_shinychat_ellmer_compatibility.R`

Run a script with:

```bat
Rscript simple_test.R
```

If your change affects launch, provider configuration, or plot updates, include
the command you used to verify the behavior in your change notes.

## Change Guidance

- Keep user-facing names consistent with `GeomWhisper`.
- Document any new environment variables, models, or provider-specific behavior.
- If a change affects manuscript-readiness for JOSS, update the relevant
  documentation in `README.md` as part of the same change.

## Reporting Issues

Once this workspace is published as a public repository, use the issue tracker
for bugs, feature requests, and support questions. Include session logs or
screenshots when they materially reduce ambiguity.