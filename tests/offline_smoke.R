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

cat("Checking render warning capture...\n")
capture_warnings <- function(plot) {
  file <- tempfile(fileext = ".png")
  grDevices::png(file)
  on.exit({ grDevices::dev.off(); unlink(file) })
  print_plot_with_warnings(plot)
}
clean_plot <- ggplot(mtcars, aes(wt, mpg)) + geom_point()
assert_true(length(capture_warnings(clean_plot)) == 0L,
            "A clean plot should render without warnings")
missing_plot <- ggplot(data.frame(x = c(1, NA, 3), y = 1:3), aes(x, y)) + geom_point()
missing_warnings <- capture_warnings(missing_plot)
assert_true(any(grepl("Removed", missing_warnings, fixed = TRUE)),
            "print_plot_with_warnings() did not capture ggplot's missing-value warning")
assert_true(!any(grepl(intToUtf8(27), missing_warnings, fixed = TRUE)),
            "Captured warnings should not contain terminal styling codes")
deprecated_plot <- ggplot(mtcars, aes(wt, mpg, size = cyl)) + geom_line()
assert_true(length(capture_warnings(deprecated_plot)) > 0L &&
              length(capture_warnings(deprecated_plot)) > 0L,
            "Deprecation warnings should be reported every time the plot is drawn")

cat("Checking warning classification...\n")
classified <- classify_plot_warnings(c(
  "Removed 16 rows containing missing values or values outside the scale range (`geom_point()`).",
  "font family not found in Windows font database",
  "Ignoring unknown parameters: `colour_typo`",
  "Something unexpected happened"
))
assert_true(identical(classified$important, c(FALSE, TRUE, TRUE, TRUE)),
            "Removed rows should be routine; font, ignored, and unknown warnings should be important")
assert_true(all(nzchar(classified$note)), "Every warning should have a plain-language note")

cat("Checking evaluation-time warnings are kept...\n")
ignored <- eval_multi_plots(
  "library(ggplot2)\np <- ggplot(mtcars, aes(wt, mpg)) + geom_point(colour_typo = 1)"
)
assert_true(isTRUE(ignored$success) && any(grepl("Ignoring unknown parameters", ignored$warnings, fixed = TRUE)),
            "eval_multi_plots() should return the ignored-parameter warning")

cat("Checking rendering environment in chat prompt...\n")
env_prompt <- build_conv_system_prompt()
assert_true(grepl("## Rendering Environment", env_prompt, fixed = TRUE) &&
              grepl(plot_device_label(), env_prompt, fixed = TRUE),
            "The chat prompt should describe the rendering environment")
assert_true(grepl("You are ONLY a ggplot2 visualization assistant", env_prompt, fixed = TRUE),
            "The ggplot2-only scope guardrail is missing from the chat prompt")

cat("Checking web-search guidance is added only when search is enabled...\n")
assert_true(grepl("any requested ggplot change", WEB_SEARCH_PROMPT, fixed = TRUE) &&
              grepl("correct a reported error or an ignored setting", WEB_SEARCH_PROMPT, fixed = TRUE),
            "Search guidance should cover any ggplot change needing verification and user-requested fixes")
assert_true(!grepl(WEB_SEARCH_PROMPT, env_prompt, fixed = TRUE),
            "Web-search guidance should not be in the base prompt")
search_prompt <- with_search_guidance(with_search_guidance(env_prompt, TRUE), TRUE)
assert_true(lengths(regmatches(search_prompt, gregexpr(WEB_SEARCH_PROMPT, search_prompt, fixed = TRUE))) == 1L,
            "Web-search guidance should appear exactly once when search is enabled")
assert_true(identical(with_search_guidance(search_prompt, FALSE), env_prompt),
            "Disabling search should restore the base prompt")

cat("\nAll offline smoke checks passed.\n")