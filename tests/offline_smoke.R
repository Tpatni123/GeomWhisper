#!/usr/bin/env Rscript

cat("=== GeomWhisper offline smoke test ===\n\n")

assert_true <- function(condition, message) {
  if (!isTRUE(condition)) stop(message, call. = FALSE)
}

source("global.R", chdir = TRUE)

cat("Loaded global helpers from global.R\n")

cat("Checking provider labels...\n")
assert_true(identical(provider_label("openai"), "OpenAI"), "provider_label('openai') failed")
assert_true(identical(provider_label("ollama"), "Ollama (local)"), "provider_label('ollama') failed")

cat("Checking filename normalization...\n")
assert_true(
  identical(make_r_varname("01 lung-data.csv"), "_01_lung_data"),
  "make_r_varname() did not normalize the filename as expected"
)

cat("Checking null-coalescing helper...\n")
assert_true(identical(NULL %||% "fallback", "fallback"), "%||% fallback behavior failed")
assert_true(identical("value" %||% "fallback", "value"), "%||% non-null behavior failed")

cat("Checking valid ggplot evaluation...\n")
valid_result <- safe_eval_plot(
  "library(ggplot2)\np <- ggplot(mtcars, aes(x = wt, y = mpg)) + geom_point()"
)
assert_true(isTRUE(valid_result$success), "safe_eval_plot() should succeed for a valid ggplot")
assert_true(inherits(valid_result$plot, "ggplot"), "safe_eval_plot() did not return a ggplot object")

cat("Checking invalid plot evaluation...\n")
invalid_result <- safe_eval_plot("1 + 1")
assert_true(!isTRUE(invalid_result$success), "safe_eval_plot() should fail for non-plot code")
assert_true(
  grepl("ggplot object", invalid_result$error, fixed = TRUE),
  "safe_eval_plot() did not return the expected diagnostic for non-plot code"
)

cat("\nAll offline smoke checks passed.\n")