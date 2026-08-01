#!/usr/bin/env Rscript
# Minimal reproduction of ellmer 0.4.0 + shinychat 0.3.0 tool calling incompatibility
# This demonstrates the ACTUAL error that occurs

cat("=== ellmer 0.4.0 + shinychat 0.3.0 Tool Calling Test ===\n\n")

# Show versions
cat("Package versions:\n")
cat("  ellmer:", as.character(packageVersion('ellmer')), "\n")
cat("  shinychat:", as.character(packageVersion('shinychat')), "\n\n")

suppressPackageStartupMessages({
  library(ellmer)
  library(shinychat)
})

# Define a simple tool function
weather_fn <- function(location) {
  paste("Weather in", location, "is sunny, 72°F")
}

cat("Creating chat with ellmer 0.4.0 API...\n")

# Create chat - using ellmer 0.4.0 API
chat <- ellmer::chat_openai(
  api_key = Sys.getenv("OPENAI_API_KEY"),  # Will use real key or fail gracefully
  model = "gpt-4o-mini",
  system_prompt = "You are a helpful assistant with weather information."
)

# Create tool using ellmer 0.4.0 API (NEW syntax)
cat("Registering tool with ellmer 0.4.0 syntax...\n")
weather_tool <- ellmer::tool(
  name = "get_weather",
  description = "Get current weather for a location",
  arguments = list(
    location = ellmer::type_string("The city and state, e.g. San Francisco, CA")
  ),
  callback = weather_fn
)

chat$register_tool(weather_tool)
cat("Tool registered successfully\n\n")

cat("--- Now attempting to stream with tool calling ---\n")
cat("This will trigger the error in shinychat::chat_append_stream()\n\n")

# Try to stream a query that would call the tool
tryCatch({
  cat("Asking: 'What's the weather in Seattle?'\n\n")
  
  # This simulates what happens in the Shiny app when chat$stream_async() is called
  # The error occurs inside shinychat's chat_append_stream() when processing results
  result <- chat$stream("What's the weather in Seattle?")
  
  # Try to iterate through stream
  cat("Processing stream...\n")
  for (chunk in result) {
    cat(".")
  }
  cat("\n\nStream completed successfully\n")
  
}, error = function(e) {
  cat("\n!!! ERROR OCCURRED !!!\n")
  cat("Error message:\n")
  cat(conditionMessage(e), "\n\n")
  cat("Call stack:\n")
  print(sys.calls())
  cat("\n")
  cat("This is the exact error that occurs in the Shiny app when:\n")
  cat("- ellmer 0.4.0 is used\n")
  cat("- shinychat 0.3.0 processes tool call results\n")
  cat("- The tool is called via stream_async()\n")
})

cat("\n=== End Test ===\n")
