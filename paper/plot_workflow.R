output <- file.path("paper", "images", "geomwhisper_workflow.png")

png(output, width = 2200, height = 720, res = 180, bg = "white")
par(mar = c(0, 0, 0, 0), xpd = NA, family = "sans")
plot.new()
plot.window(xlim = c(0, 12), ylim = c(0, 4))

orange <- "#C8541A"
dark <- "#2C3E50"
muted <- "#6C757D"
local_fill <- "#FFF8F2"

draw_box <- function(x, y, width, height, title, subtitle, fill, border = orange) {
  rect(x, y, x + width, y + height, col = fill, border = border, lwd = 2)
  text(x + width / 2, y + height * 0.64, title, cex = 1.15, font = 2, col = dark)
  text(x + width / 2, y + height * 0.31, subtitle, cex = 0.83, col = muted)
}

draw_arrow <- function(x1, y1, x2, y2, color = dark) {
  arrows(x1, y1, x2, y2, length = 0.10, lwd = 2, col = color)
}

text(0.45, 3.62, "GeomWhisper workflow", adj = c(0, 0.5), cex = 1.75, font = 2, col = dark)
text(0.45, 3.23, "Load data and code, review the plot, then request a change by voice or chat.",
     adj = c(0, 0.5), cex = 0.94, col = muted)

rect(0.35, 1.15, 11.65, 2.75, border = orange, lwd = 2, lty = 2)
text(0.62, 2.54, "LOCAL R SESSION", adj = c(0, 0.5), cex = 0.82, font = 2, col = orange)

draw_box(1.00, 1.62, 1.72, 0.78, "Load data", "CSV, XLSX, XLS, or RDS", local_fill)
draw_box(3.15, 1.62, 1.82, 0.78, "Add ggplot code", "Upload or paste an R script", local_fill)
draw_box(5.40, 1.62, 1.48, 0.78, "Click Load", "Evaluate and preview", local_fill)
draw_box(7.31, 1.62, 1.84, 0.78, "Review plot", "Select the active figure", local_fill)
draw_box(9.58, 1.62, 1.48, 0.78, "Request change", "Speak or type", local_fill)

draw_arrow(2.74, 2.01, 3.13, 2.01)
draw_arrow(4.99, 2.01, 5.38, 2.01)
draw_arrow(6.90, 2.01, 7.29, 2.01)
draw_arrow(9.17, 2.01, 9.56, 2.01)

text(6.00, 0.62,
     "Raw uploaded data remain in the local R session and are not included in the standard LLM prompt.",
     cex = 0.92, font = 2, col = dark)

dev.off()