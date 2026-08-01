# Preamble Dependency Extraction for Multi-Plot LLM Isolation

## The Problem

When a user uploads a multi-plot R script, the app splits it into:

- **Preamble** — shared setup: data loading, wrangling, derived variables, plot setup objects
- **Per-plot blocks** — one block per ggplot object (e.g. `facet_plot`, `histogram`)

Only the **active plot's code block** is sent to the LLM as context. This prevents context
clutter from other plots — the whole point of isolation.

However, the preamble often defines variables that the plot block *references but does not
define*. The LLM sees references to these variables without knowing what they contain, which
causes hallucination or broken code when the user asks to modify them.

### Concrete example (from an actual user script)

The plot block references:

```r
facet_plot <- ggplot(dm_filtered, aes(...)) +
  facet_manual(
    ~facet_label,
    design   = design,
    labeller = custom_labeller,
    strip    = strip_themed(
      background_x = elem_list_rect(fill = strip_colors)
    )
  ) + ...
```

But these variables are **all defined in the preamble**:

| Variable | What it is | Why it matters |
|---|---|---|
| `strip_colors` | `c(rep("#9ECAE1", n_with), rep("#FDAE6B", n_without))` | Facet strip fill colours — user wants to change these |
| `n_with` / `n_without` | Integer counts of patient groups | Referenced inside `strip_colors` definition |
| `design` | A matrix defining the custom facet layout | LLM needs to understand panel structure |
| `custom_labeller` | A closure mapping facet labels to patient ages | Determines what the strip labels show |
| `age_map` | Named character vector used inside `custom_labeller` | Referenced by the closure body |
| `dm_filtered` | Data frame — the filtered dataset powering the plot | LLM needs column names, factor levels, row count |
| `group_annot_data` | 2-row data frame for group annotation text | Passed to `geom_text()` |

When the user says *"change the awake group strip to green"*, the LLM sees `strip_colors`
in the plot code but has no idea it's `c(rep("#9ECAE1", 7), rep("#FDAE6B", 8))`. It guesses,
produces structurally broken code.

---

## Why Sending Raw Preamble Source Is Wrong

The naive fix — send the preamble source text alongside the plot block — has two problems:

1. **Context bloat.** The preamble contains all the data wrangling, column renames,
   merges, and intermediate objects irrelevant to the active plot. This wastes tokens
   and dilutes the LLM's attention.

2. **Unresolved references.** `strip_colors` is defined as
   `c(rep("#9ECAE1", n_with), rep("#FDAE6B", n_without))` — which still requires the
   LLM to know `n_with` and `n_without`. The dependency chain propagates.

---

## The Proposed Solution

### Core idea: send computed values, not source expressions

`split_script()` already evaluates the entire preamble into a live R environment (`env`)
in order to identify which expressions produce ggplot objects. That evaluated environment
holds the **concrete, final values** of every preamble variable.

Instead of re-parsing source text, `extract_preamble_deps()` reads values out of `env`
directly and serialises them to text by type — eliminating all unresolved references.

### Selection criterion

A preamble variable is included if and only if its name appears as a **whole word** in the
active plot block's source text (using `\b` word-boundary regex). This is intentionally
conservative: it only includes what the plot explicitly names.

### Serialisation by type

| R type | What the LLM receives |
|---|---|
| `data.frame` | Compact structural summary: row/col count, each column's type + range/levels. **No raw data rows.** |
| Small atomic (≤ 100 elements) | `dput()` output — exact R literal. `strip_colors` becomes `c("#9ECAE1", "#9ECAE1", ..., "#FDAE6B")` |
| Large atomic (> 100 elements) | `str()` output — structural overview |
| User-defined function | Deparsed source via `deparse()`. The closure body may reference further preamble vars, which will also be picked up by the word-boundary filter. |
| Package function | Skipped — not user-authored, LLM already knows these |
| `gg` object / environment | Skipped — not representable as useful text |

### Transitive resolution (automatic)

When a user-defined function like `custom_labeller` is included via `deparse()`, its body
text contains `age_map`. On the same filter pass, `age_map` is also in `all_vars` and its
name appears as a whole word in the **combined text** of plot code + serialised deps. This
means transitively-needed variables surface naturally — no explicit dependency graph is
needed.

> Note: the current implementation runs the word-boundary filter only against `plot_code`,
> not against the already-serialised deps. True transitive resolution would require a
> second pass over the accumulated `parts` text. This is a known gap but acceptable for
> typical scripts — the depth of transitive deps is rarely > 1.

---

## What the LLM Receives (example output)

```
## Plot Setup Variables (read-only context)
These variables are defined in the shared preamble and referenced by this plot's code.
They are shown so you understand the plot's structure.
Do NOT redefine or include them in your update_plot() response — only return the active plot block.

n_with <- 7L

n_without <- 8L

strip_colors <- c("#9ECAE1", "#9ECAE1", "#9ECAE1", "#9ECAE1", "#9ECAE1",
"#9ECAE1", "#9ECAE1", "#FDAE6B", "#FDAE6B", "#FDAE6B", "#FDAE6B",
"#FDAE6B", "#FDAE6B", "#FDAE6B", "#FDAE6B")

design <- structure(c(1L, 2L, NA, 3L, 4L, NA, 5L, 6L, NA, 7L, 8L,
9L, 10L, 11L, 12L, 13L, 14L, 15L), dim = c(3L, 5L))

age_map <- c(`with_ana_50318229` = "4", `with_ana_60251` = "6", ...)

custom_labeller <- function(x) age_map[x]

# group_annot_data: data.frame [2 rows x 2 cols]
# Columns: facet_label <factor: with_ana_50318229, without_ana_60251>; group_label <character>

# dm_filtered: data.frame [87 rows x 19 cols]
# Columns: MRN <numeric [50101, 60251]>; Week <numeric [1, 6]>;
#   gp <factor: with_ana, without_ana>; 3D Vector (mm) <numeric [0.1, 8.4]>;
#   facet_label <factor: with_ana_50318229, ... +14 more>; ...
```

---

## Implementation Location

All logic lives in `global.R`:

- `split_script()` — returns `preamble_env` and `extra_var_names` alongside the existing
  `preamble` and `plot_codes`
- `extract_preamble_deps(preamble_env, plot_code, exclude_names, max_elements)` — produces
  the text block above
- `.format_dep_df(nm, df)` — helper for the data.frame case

In `server.R`:

- `rv$preamble_env` and `rv$preamble_env_extra_names` — stored as reactive values
- `init_chat()` — calls `extract_preamble_deps()` and passes the result to
  `build_conv_system_prompt()` as the `preamble_deps` argument
- The prompt section is labelled `## Plot Setup Variables (read-only context)` and
  injected **before** `## Current Plot Code` so the LLM has context before seeing the code

---

## Known Gaps / Future Work

1. **Single-pass transitive resolution** — if `custom_labeller` references `age_map`,
   `age_map` is only included if it also appears as a whole word directly in `plot_code`.
   A second-pass scan of the already-serialised deps text would close this gap.

2. **`next` inside `tryCatch`** — the current code uses `next` inside a `tryCatch` block,
   which is valid in R but worth auditing if the control flow becomes more complex.

3. **Large `dput()` output** — a named list with many entries could exceed the `max_elements`
   threshold incorrectly (since `length()` of a list is the number of top-level elements,
   not total elements). May want type-specific size checks for lists.

4. **Re-initialisation on plot switch** — `extract_preamble_deps()` is called inside
   `init_chat()`, which fires when the user switches the active plot. The same `preamble_env`
   is reused but the `plot_code` changes, so the deps text is correctly recomputed per plot.
