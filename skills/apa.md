# APA Style — Figure Requirements

## Overview
These requirements follow the Publication Manual of the American Psychological Association (7th Edition).

## Theme
- Use `theme_apa()` from the `jtools` package, or manually recreate with `theme_classic()` plus:
  - White background, no gridlines
  - Bold axis labels
  - No top or right border lines

```r
theme_apa_manual <- function(base_size = 12) {
  theme_classic(base_size = base_size) +
    theme(
      axis.title   = element_text(face = "bold"),
      axis.text    = element_text(color = "black"),
      legend.title = element_text(face = "bold"),
      panel.border = element_blank()
    )
}
```

## Figure Dimensions
- Typical width: 3.5 inches (single column) or 7 inches (full width).
- Height: 3–3.5 inches.
- Resolution for publication: 300 DPI minimum; 600 DPI preferred.

## Colors
- Grayscale preferred for print compatibility. Use varying shades: `"black"`, `"gray50"`, `"gray80"`.
- If color is used, ensure figures are interpretable in grayscale.
- Do not rely on color alone to distinguish groups — also vary shape (`shape`) or linetype (`linetype`).

## Axes
- Both x and y axis labels are **bold** and sentence case (capitalize first word only).
- Include units in parentheses: `"Reaction time (ms)"`.
- Start y-axis at 0 unless displaying change/deviation scores.
- Use `scale_y_continuous(expand = expansion(mult = c(0, 0.05)))` to anchor bars at y = 0.

## Bar Charts
- Use `geom_col()` with `fill = "gray70"` for simple bar charts.
- Add error bars representing ±1 SE or 95% CI with `geom_errorbar(width = 0.2)`.
- No 3D effects, shadows, or gradients.

## Scatter Plots
- Use `geom_point(shape = 16, size = 2)`.
- Add regression line with `geom_smooth(method = "lm", color = "black", se = FALSE)`.

## Legend
- Title in bold. Position: outside the plot (default).
