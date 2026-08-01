# Nature Journal — Figure Requirements

## Style Guide
These requirements apply to all figures submitted to *Nature* family journals.

## General Formatting
- Use `theme_classic()` as the base theme — clean white background, no gridlines.
- Font: use `base_family = "Arial"` or `base_family = "Helvetica"` in the theme.
- Minimum base font size: 7 pt (`base_size = 7`). Max label text: 9 pt.
- Figure width: typically 89 mm (single column) or 183 mm (double column). When exporting, use width_in = 3.5 or width_in = 7.2.

## Colors
- Use colorblind-friendly palettes. Prefer `scale_color_manual` or `scale_fill_manual` with:
  - Blue: `#0072B2`
  - Orange: `#E69F00`
  - Green: `#009E73`
  - Red: `#D55E00`
  - Purple: `#CC79A7`
- Avoid red/green combinations.

## Axes and Labels
- Include clear, concise axis titles with units in parentheses, e.g., `"Time (days)"`.
- Remove axis ticks that are not needed. Keep only major ticks.
- Use `labs(title = NULL)` — Nature figures do not use panel titles; use figure legends instead.

## Lines and Points
- Point size: `size = 1.5` for scatter plots.
- Line width: `linewidth = 0.8` for line plots.
- Error bars: use `geom_errorbar(width = 0.1)`.

## Legend
- Place legend inside the plot if space allows: `theme(legend.position = c(0.85, 0.85))`.
- Remove legend title when redundant: `theme(legend.title = element_blank())`.

## Statistical Annotations
- Use `geom_smooth(method = "lm", se = TRUE)` for regression with confidence intervals.
- Significance brackets: add via `annotate("segment", ...)` + `annotate("text", label = "**", ...)`.

## Example Snippet
```r
theme_set(theme_classic(base_size = 7, base_family = "Arial"))

p <- ggplot(data, aes(x = x_var, y = y_var, color = group)) +
  geom_point(size = 1.5, alpha = 0.8) +
  scale_color_manual(values = c("#0072B2", "#E69F00", "#009E73")) +
  labs(x = "X Variable (units)", y = "Y Variable (units)", color = NULL) +
  theme(legend.position = c(0.85, 0.85))
```
