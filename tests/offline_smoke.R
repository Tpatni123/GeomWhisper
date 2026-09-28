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

cat("Checking web-search provider capabilities...\n")
assert_true(web_search_supported("openai"), "OpenAI should support web search")
assert_true(web_search_supported("anthropic"), "Anthropic should support web search")
assert_true(web_search_supported("google"), "Google should support web search")
assert_true(!web_search_supported("ollama"), "Ollama should remain local-only")

sentinel_tool <- structure(list(name = "update_plot"), class = "sentinel_tool")
plain_tools <- build_request_tools("ollama", sentinel_tool, web_search_enabled = FALSE)
assert_true(length(plain_tools) == 1L, "Plain requests should contain only update_plot")
assert_true(identical(plain_tools[[1]], sentinel_tool), "Plain tool selection changed update_plot")
unsupported_error <- tryCatch(
  {
    build_request_tools("ollama", sentinel_tool, web_search_enabled = TRUE)
    NULL
  },
  error = function(e) conditionMessage(e)
)
assert_true(
  identical(unsupported_error, "Web search is not supported for provider: ollama"),
  "Ollama web-search requests should fail clearly"
)

cat("Checking native web-search tool construction...\n")
for (provider in c("openai", "anthropic", "google")) {
  tools <- build_request_tools(provider, sentinel_tool, web_search_enabled = TRUE)
  assert_true(length(tools) == 2L, paste(provider, "should receive plot and web-search tools"))
  assert_true(identical(tools[[1]], sentinel_tool), paste(provider, "lost the update_plot tool"))
  assert_true(
    inherits(tools[[2]], "ellmer::ToolBuiltIn"),
    paste(provider, "did not receive an ellmer built-in web-search tool")
  )
}

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