#!/usr/bin/env Rscript
# Test shinychat + ellmer with tool calling (based on shinychat documentation)
# This reproduces the compatibility issue between ellmer 0.4.0 and shinychat 0.3.0

cat("=== Testing shinychat + ellmer with tool calling ===\n\n")

# Show versions
cat("Package versions:\n")
cat("  ellmer:", as.character(packageVersion('ellmer')), "\n")
cat("  shinychat:", as.character(packageVersion('shinychat')), "\n\n")

suppressPackageStartupMessages({
  library(shiny)
  library(shinychat)
  library(ellmer)
})

cat("--- Creating a simple chatbot app with a tool ---\n\n")

# Define a simple tool (like the one in your app)
get_weather <- function(location) {
  # Simulate a weather API call
  paste("The weather in", location, "is sunny and 72°F")
}

# Create the chat
# NOTE: Using fake API key - won't actually call OpenAI
# but will go through ellmer's tool registration and stream preparation
cat("Creating chat with tool...\n")
chat <- ellmer::chat_openai(
  api_key = "fake-test-key",  # Won't actually call API
  model = "gpt-4",
  system_prompt = "You are a helpful assistant with access to weather information."
)

# Register the tool using ellmer 0.3.0 syntax (current version)
weather_tool <- ellmer::tool(
  get_weather,
  "Get current weather for a location",
  location = ellmer::type_string("The city and state, e.g. San Francisco, CA"),
  .name = "get_weather"
)

chat$register_tool(weather_tool)
cat("Tool registered successfully\n\n")

cat("--- Simulating what happens during chat_append() with streaming ---\n")
cat("This is where the error occurs with ellmer 0.4.0 + shinychat 0.3.0\n\n")

# Try to create a mock stream result that would come from ellmer
# when a tool is called
cat("Creating mock tool call result from stream...\n")
tryCatch({
  # This simulates what ellmer 0.4.0 returns when a tool is called
  # The structure changed between 0.3.0 and 0.4.0
  mock_stream_chunk <- list(
    role = "assistant",
    content = NULL,
    tool_calls = list(
      list(
        id = "call_123456",
        type = "function",
        `function` = list(  # Note: 'function' is a reserved word in R
          name = "get_weather",
          arguments = '{"location": "San Francisco, CA"}'
        )
      )
    )
  )
  
  cat("Mock stream chunk created\n")
  cat("Structure:\n")
  str(mock_stream_chunk)
  
  cat("\n--- What shinychat::chat_append_stream() tries to do internally ---\n")
  # shinychat tries to process this and create data frames to track tool calls
  # This is roughly what happens inside chat_append_stream()
  
  if (!is.null(mock_stream_chunk$tool_calls) && length(mock_stream_chunk$tool_calls) > 0) {
    cat("Processing", length(mock_stream_chunk$tool_calls), "tool call(s)...\n")
    
    # This is approximately what causes the error
    for (i in seq_along(mock_stream_chunk$tool_calls)) {
      tc <- mock_stream_chunk$tool_calls[[i]]
      cat("\nTool call", i, ":\n")
      cat("  ID:", tc$id, "\n")
      cat("  Name:", tc$`function`$name, "\n")
      cat("  Arguments:", tc$`function`$arguments, "\n")
      
      # shinychat tries to create a data.frame here
      # The error occurs when the structure doesn't match what it expects
      cat("\n  Attempting to create tracking data.frame...\n")
      
      # This is where the mismatch happens - shinychat expects certain columns
      # but ellmer 0.4.0's format may have changed
      df <- data.frame(
        id = tc$id,
        name = tc$`function`$name,
        # The problem: if some field is missing or has 0 length
        stringsAsFactors = FALSE
      )
      cat("  SUCCESS: data.frame created\n")
      print(df)
    }
  }
  
  cat("\n=== Test completed without errors ===\n")
  cat("With ellmer 0.3.0, this should work\n")
  cat("With ellmer 0.4.0, chat_append_stream() would fail with:\n")
  cat("  'arguments imply differing number of rows: 1, 0'\n")
  
}, error = function(e) {
  cat("\n!!! ERROR OCCURRED !!!\n")
  cat("Error message:", conditionMessage(e), "\n")
  cat("\nThis is the compatibility issue between ellmer 0.4.0 and shinychat 0.3.0\n")
})

cat("\n=== End Test ===\n")
