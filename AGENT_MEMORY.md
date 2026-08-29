# GeomWhisper Agent Memory

Last updated: 2026-08-28

## Purpose

This file is a portable handoff for another coding agent working on GeomWhisper.
The recent work focused on reducing the time between submitting a plot-edit
request and seeing the updated plot in the Shiny UI.

## Project overview

- Application: local R Shiny app for conversational and voice-driven ggplot2
  editing.
- Main files:
  - `global.R`: shared helpers, plot evaluation, prompt construction, model
    setup, and the local command fast path.
  - `server.R`: Shiny reactive state, chat/voice handlers, plot updates,
    multi-plot support, undo/reset, and export.
  - `ui.R`: Shiny UI.
  - `www/speech.js`: browser speech-recognition integration.
  - `tests/offline_smoke.R`: current offline regression suite.
- Current configured test provider/model: OpenAI `gpt-5-mini`.
- Do not copy API keys into source code or this memory file. Provider settings
  are stored in the user's R configuration directory.

## Original latency diagnosis

The visible delay consists of:

1. provider/model generation;
2. generated R-code evaluation;
3. ggplot rendering;
4. Shiny/browser delivery.

Measured local costs for the default plot:

- code evaluation: about 0.01 seconds median;
- one 700 x 500 plot render: about 0.12 seconds median;
- the old render plus an unused PNG cache copy: about 0.13 seconds median.

The original provider-backed plot edits took approximately:

- 23.4 seconds;
- 12.6 seconds;
- average: 18.01 seconds.

After local cleanup and prompt reduction, two provider-backed edits took:

- 16.5 seconds;
- 11.9 seconds;
- average: 14.21 seconds.

That roughly four-second difference was considered too small and too sensitive
to provider variance to be a meaningful UX improvement.

## Exact workflow changes

This section describes how the application workflow changed, not just the
individual code optimizations.

### Workflow before the changes

Every typed or voice plot-edit request followed the same provider-backed path:

```text
Typed chat or voice transcript
  -> Shiny input event
  -> ellmer stream_async()
  -> selected LLM provider/model
  -> model generates a tool call containing R code
  -> update_plot_fn()
  -> evaluate the generated script
  -> update reactive plot state
  -> renderPlot() prints the plot
  -> dev.copy() renders another unused PNG
  -> browser receives the updated plot
```

Consequences of the old workflow:

- even a deterministic request such as "change points to red" waited for the
  complete model round trip;
- multi-plot edits re-ran the shared preamble before evaluating one plot;
- the plot was rendered twice because of the unused PNG copy;
- the first render could update its own reactive dependency and schedule another
  render;
- the model received a longer, duplicated system prompt.

### Workflow after the changes

Typed and voice requests now enter one shared routing decision:

```text
Typed chat or voice transcript
  -> parse_fast_plot_command()
  -> Is this one supported, unambiguous, visual-only action?
       |
       +-- YES: local fast path
       |     -> status: Evaluating R code
       |     -> build_fast_plot_update()
       |     -> update_plot_fn()
       |     -> evaluate locally
       |     -> update reactive plot/code/history state
       |     -> status: Rendering plot
       |     -> render once
       |     -> status: Applied locally
       |     -> synchronize the ellmer system prompt with current code
       |     -> append "Applied locally" response to chat
       |
       +-- NO: existing model path
             -> status: Waiting on model
             -> ellmer stream_async()
             -> selected provider/model
             -> model tool call
             -> status: Evaluating R code
             -> update_plot_fn()
             -> evaluate locally
             -> update reactive plot/code/history state
             -> status: Rendering plot
             -> render once
             -> status: Ready
```

The selected provider and model are not changed by this routing. The app only
skips the provider when the requested operation can be applied deterministically
and safely.

### Typed chat workflow

Changed in `server.R`:

1. `input$chat_user_input` is trimmed and validated.
2. `apply_fast_plot_command()` runs before `chat_obj()$stream_async()`.
3. A recognized local command is applied immediately and the handler returns,
   so no provider request is sent.
4. An unsupported command continues into the original asynchronous model
   workflow.
5. The typed user message remains visible through the existing shinychat input
   behavior.

### Voice workflow

Changed in `server.R`:

1. `www/speech.js` still sends the completed transcript through `voice_text`.
2. The existing two-second duplicate-transcript guard still runs.
3. `apply_fast_plot_command(..., append_user = TRUE)` now runs before the model.
4. For a local command, the server appends both the user transcript and local
   completion message to shinychat.
5. For a fallback command, the server keeps the original behavior: append the
   user transcript and stream the model response.

The previous early `req(chat_obj())` was moved after the fast-path attempt. This
allows a valid local edit to run without unnecessarily depending on model
availability.

### Local command workflow

Implemented in `global.R` and `server.R`:

1. `parse_fast_plot_command()` accepts only one clearly supported action.
2. It validates values:
   - colors must be a recognized R color or six/eight-digit hex value;
   - point size must be numeric and between 0.1 and 20;
   - labels are length-limited;
   - legend position must be top, bottom, left, right, or none.
3. `build_fast_plot_update()` confirms:
   - the active object is a ggplot;
   - the plot has a valid variable name;
   - point commands target at least one point layer.
4. It produces standalone R code and passes that code through the existing
   `update_plot_fn()` path. It does not mutate reactive state through a separate,
   inconsistent shortcut.
5. The normal code history, validation, plot state, thumbnail state, and undo
   mechanisms therefore remain authoritative.
6. Generated sections are wrapped with:

   ```text
   # GeomWhisper fast edit: <operation>
   ...
   # End GeomWhisper fast edit
   ```

7. A repeated local edit of the same type replaces its earlier generated
   section instead of continually expanding the script.
8. The chat receives an explicit local response:

   ```text
   Applied locally without a model round trip.
   ```

### Conservative fallback workflow

The local parser returns no action and sends the original request to the model
when it sees:

- multiple requested actions joined by words such as "and", "also", or "plus";
- ambiguous styling, such as "make the title bigger";
- explanatory questions;
- unsupported visual changes;
- statistical or data-transforming changes;
- invalid values;
- point changes on a plot without a point layer;
- unnamed bare plot expressions that cannot be updated safely in source code.

This fallback is intentional. The local path must never guess at user intent to
gain speed.

### Model fallback workflow

The model path remains based on the persistent per-session ellmer chat object:

```text
unsupported request
  -> request status becomes "Waiting on model"
  -> chat_obj()$stream_async()
  -> provider returns update_plot tool call
  -> request status becomes "Evaluating R code"
  -> update_plot_fn() validates and evaluates code
  -> request status becomes "Rendering plot"
  -> model receives tool result and code diff
  -> model returns the visual-change summary
  -> request status returns to "Ready"
```

For OpenAI GPT-5-family models, `create_session_chat()` now passes low reasoning
effort through `api_args`. The selected model name remains unchanged. Other
models and providers keep their existing request arguments.

### Request-status indicator workflow

The sidebar now contains a full-width, accessible request-status bar below the
provider/model badge. It uses `role="status"` and `aria-live="polite"` and maps
the internal lifecycle to these visible states:

| Internal stage | Visible label | Meaning |
| --- | --- | --- |
| `idle` | Ready | No plot request is active. |
| `waiting_model` | Waiting on model | The selected provider/model is producing a response. |
| `evaluating` | Evaluating R code | Generated or local R code is being validated and evaluated. |
| `rendering` | Rendering plot | Shiny is printing and sending the new plot. |
| `applied_local` | Applied locally | The completed request bypassed the model. |
| `error` | Request failed | Evaluation, rendering, or request startup failed. |

`request_id` prevents an older completion callback from overwriting the status
of a newer request. Local edits are deferred with `session$onFlushed()` so the
browser receives "Evaluating R code" before the fast evaluation starts.
`renderPlot()` changes an active evaluated request to "Rendering plot" and, after
the browser flush plus a short 450 ms visibility interval, settles on "Applied
locally" for local edits or "Ready" for model edits.

Model streams are wrapped in an async generator. If the model answers without
calling `update_plot`, the wrapper resets "Waiting on model" to "Ready" when the
stream completes. If the stream terminates with an error while still waiting,
the status becomes "Request failed." This prevents the indicator from remaining
stuck after non-plot conversational replies.

### Chat-context synchronization workflow

A local edit does not create a model turn, so the persistent model chat would
otherwise retain an old system prompt containing stale plot code.

After a successful local edit, `sync_chat_system_prompt()` now:

1. reads the latest full or active-plot code;
2. rebuilds the conversational system prompt;
3. includes current data, journal, sheet, multi-plot, and preamble dependency
   context;
4. calls `chat$set_system_prompt()` on the existing chat object.

This updates the model's view of the current plot without discarding its
existing conversation turns.

### Single-plot evaluation workflow

Single-plot updates still pass complete code through `eval_multi_plots()`.
The change is that a recognized local command produces the modification without
waiting for the model first.

```text
local or model-generated full script
  -> package check
  -> eval_multi_plots()
  -> rv$current_code
  -> rv$current_plot
  -> renderPlot()
```

### Multi-plot loading workflow

The initial multi-plot load still evaluates the full script once to discover
plots. Then `split_script()`:

1. separates shared preamble expressions from individual plot blocks;
2. records each plot's source block;
3. captures the non-plot preamble values visible when each plot is created;
4. stores those values in `plot_dep_contexts`;
5. builds compact dependency text for the active plot's model prompt.

### Multi-plot update workflow

Before:

```text
active plot edit
  -> evaluate shared preamble again
  -> evaluate active plot block
  -> update active plot
```

After:

```text
active plot edit
  -> find captured dependency snapshot
  -> evaluate only active plot block against captured values
  -> splice updated block into plot_codes
  -> rebuild current full script
  -> update only the active plot reactive value
```

If a dependency snapshot is unavailable, `eval_isolated_plot()` explicitly
falls back to evaluating the preamble plus the active block. Evaluation errors
are still surfaced rather than silently ignored.

### Plot rendering workflow

Before:

```text
renderPlot()
  -> print(plot)
  -> dev.copy() to PNG
  -> close copied device
  -> store PNG path that no caller uses
```

After:

```text
renderPlot()
  -> if a request was evaluated, set status to "Rendering plot"
  -> print(plot) once
  -> Shiny sends plot to browser
  -> after browser flush, settle status to "Applied locally" or "Ready"
```

The unused `current_plot_png` reactive field, `dev.copy()` block, and
`ggplot_image_content()` helper were removed.

### Initial plot and dataset workflow

Before, `renderPlot()` could evaluate missing plot state and write the result
back to `rv$current_plot` while depending on that same reactive value.

After:

1. the default plot is evaluated once when the server session initializes;
2. `rv$current_plot` begins with that object;
3. generated starter code for an uploaded dataset is evaluated before assigning
   the new current plot;
4. `renderPlot()` consumes plot state but does not write back to its own reactive
   dependency.

This removed the duplicate Shiny recalculation state errors seen in the browser.

### Undo, reset, thumbnails, and export

These workflows continue to use the existing application state:

- every successful local or model update enters `code_history`;
- undo re-evaluates the restored source and rebuilds multi-plot state;
- reset restores the pre-evaluated default plot;
- active multi-plot thumbnails continue to use `rv_single_plots`;
- export continues to print `rv$current_plot` at the requested format and
  dimensions.

No separate fast-path state was introduced, which prevents local edits from
becoming disconnected from undo, thumbnails, or export.

## Changes already implemented

### 1. Multi-plot preamble reuse

`split_script()` already captures the values created by a multi-plot script's
shared preamble. Isolated plot edits now use those captured values through
`eval_isolated_plot()` instead of re-running the entire preamble.

Behavior:

- isolated multi-plot edit with a dependency snapshot: evaluate only the active
  plot block;
- missing snapshot: fall back to the full preamble plus plot block;
- single-plot scripts: continue evaluating their complete code.

Synthetic benchmark with a 0.2-second setup:

- cached isolated path: 0.000 seconds median;
- full-preamble fallback: 0.220 seconds median.

### 2. Removed redundant rendering

The main `renderPlot()` previously printed the plot and then used `dev.copy()` to
create a PNG that was never consumed. The PNG cache state and dead image helper
were removed.

The initial render also wrote to `rv$current_plot` from inside a reactive output
that depended on the same value. This self-invalidation caused duplicate Shiny
recalculation messages and an extra render. The default plot is now evaluated
once at session initialization and stored before `renderPlot()` runs.

### 3. Reduced model prompt size

The duplicated conversational instructions and tool descriptions were condensed
while retaining:

- required tool use for plot edits;
- active-plot isolation;
- valid runnable R code;
- uploaded-data references;
- preservation of existing plot style;
- statistical-change disclosure;
- the ggplot-only scope restriction;
- concise post-update summaries.

The static system prompt is now approximately 1,696 characters.

### 4. Local fast path for common edits

Common, unambiguous, single-action commands bypass the model completely:

- point color;
- point size;
- plot title;
- X-axis label;
- Y-axis label;
- legend position.

Examples:

```text
Change the points to red
Set point size to 5
Change the plot title to "Fuel Economy"
Set x-axis label to Vehicle Weight
Move the legend to bottom
```

Supported edits are parsed by `parse_fast_plot_command()` and converted to
standalone R code by `build_fast_plot_update()`. The generated blocks are marked
and repeated edits of the same type replace the previous generated block instead
of growing the script indefinitely.

The fast path is intentionally conservative. It falls back to the configured
model when a request is:

- compound, such as "change the points to red and make them larger";
- ambiguous, such as "make the title bigger";
- explanatory;
- statistical;
- unsupported;
- directed at a plot without the required geom;
- based on a bare unnamed plot expression.

Typed and voice commands both use the fast path. After a local edit, the ellmer
chat object's system prompt is synchronized with the new current code so later
model requests receive the updated plot state.

### 5. GPT-5 fallback request setting

OpenAI models whose names begin with `gpt-5` retain the selected model but send:

```r
api_args = list(reasoning_effort = "low")
```

Other OpenAI models and other providers keep their previous request settings.
This setting has not been separately benchmarked because provider timing is
variable and the main measured gain comes from bypassing the provider for local
commands.

## Meaningful latency result

Final integrated-browser timings for local fast-path commands:

- point color: 0.51-0.65 seconds;
- point size: 0.33 seconds;
- multi-plot point color: 0.48 seconds;
- voice-triggered point size: 0.48 seconds;
- final three-command single-plot average: 0.495 seconds.

For supported commands, this is approximately 96-97% faster than the previous
14-18 second provider-backed averages.

Complex and unsupported requests still depend on model/provider latency.

## Verification already completed

The following behaviors were verified:

- default plot startup;
- no previous Shiny self-invalidation console errors;
- typed local edits;
- voice local edits;
- repeated point-color edit compaction;
- single-plot edits;
- isolated multi-plot edits;
- active thumbnail preservation;
- undo and reset;
- PNG export returning HTTP 200 with `image/png`;
- conservative fallback parser boundaries;
- valid and invalid ggplot evaluation;
- prompt-contract invariants.

The offline smoke suite passed after the final changes:

```powershell
Set-Location "C:\path\to\GeomWhisper"
Rscript tests\offline_smoke.R
```

On the development machine, the tested interpreter was:

```text
C:\Users\tpatni\AppData\Local\Programs\R\R-4.4.2\bin\Rscript.exe
```

VS Code diagnostics reported no errors in `global.R`, `server.R`, or
`tests/offline_smoke.R`.

## Profiling artifacts

The original profiling report was stored outside the project in the Copilot
session folder, so it may not be present on another laptop. If available, its
name is:

```text
debrief-report.html
```

The important measured results are preserved in this file, so the report is not
required to continue development.

## Current local launch

A development instance was last launched with:

```powershell
Set-Location "C:\path\to\GeomWhisper"
Rscript -e "shiny::runApp('.', host='127.0.0.1', port=7480, launch.browser=FALSE)"
```

The packaged launcher normally uses port 7475.

## Recommended next improvements

Prioritize changes that affect unsupported or complex requests, because the
supported local commands are already sub-second.

### High priority

1. Add structured request-stage timing:
   - submit time;
   - first model token;
   - tool-call receipt;
   - R evaluation complete;
   - browser plot rendered.
   Keep logs free of API keys and sensitive uploaded data.

2. Expand the conservative local grammar for clearly deterministic operations:
   - point shape with an explicit shape value;
   - line color/width for plots with one unambiguous line layer;
   - explicit theme names;
   - font size for an explicitly named title or axis element;
   - remove legend/title.
   Every expansion must include false-positive tests.

3. Measure provider fallback latency with a larger controlled sample. Compare
   median and p90/p95, not only the mean. Do not claim an improvement from fewer
   than roughly 20 comparable requests.

### Medium priority

5. Add dedicated `testthat` coverage if the project adopts `testthat`.
   Do not introduce a new test framework solely for one small change.

6. Consider a formal command schema shared by text and voice inputs instead of
   adding many independent regular expressions.

7. Consider client-side visual previews only if server state and generated R
   code remain authoritative and synchronized.

## Guardrails for future agents

- Preserve the selected provider and model unless the user explicitly requests
  a model change.
- Never treat a small average difference from a few provider calls as proof of
  improvement.
- Prefer deterministic local execution only when intent is unambiguous.
- Unsupported commands must fall back to the model rather than being guessed.
- Keep generated plot code valid outside the running Shiny session.
- Keep undo, multi-plot selection, code history, and export synchronized.
- Do not broaden the R evaluation environment or weaken existing validation.
- Do not add broad error catches or silently ignore failed local edits.
- Do not log or commit API keys, uploaded private data, or configuration files.
- Run `tests/offline_smoke.R` after changing plot evaluation, command parsing,
  prompt construction, or chat routing.

## Suggested first prompt for the next agent

```text
Read AGENT_MEMORY.md, then inspect global.R, server.R, and
tests/offline_smoke.R. Preserve the existing local fast path and conservative
fallback behavior. Add request-stage timing instrumentation that clearly
separates provider latency, R evaluation, and Shiny rendering. Run the existing
offline smoke test and verify the app in a browser before reporting results.
Do not expose or modify saved API credentials.
```
