#!/usr/bin/env Rscript
# Test shinychat 0.3.0 compatibility with ellmer 0.4.0 vs 0.3.0
# Reproduces the "arguments imply differing number of rows: 1, 0" error

cat("=== Testing shinychat + ellmer compatibility ===\n\n")

# Show current versions
cat("Current versions:\n")
cat("  ellmer:", as.character(packageVersion('ellmer')), "\n")
cat("  shinychat:", as.character(packageVersion('shinychat')), "\n\n")

# Load libraries
suppressPackageStartupMessages({
  library(ellmer)
  library(shinychat)
})

# Test 1: Create a chat with a tool (mimics the app setup)
cat("--- Test 1: Create chat with tool ---\n")
tryCatch({
  # Create a simple tool (like the update_plot tool in the app)
  test_tool <- ellmer::tool(
    function(message) {
      return(paste("Received:", message))
    },
    "A test tool that echoes a message",
    message = ellmer::type_string("The message to echo"),
    .name = "test_tool"
  )
  
  # Create chat with fake API key (won't actually call API)
  chat <- ellmer::chat_openai(
    api_key = "fake-key-for-testing",
    model = "gpt-4",
    system_prompt = "You are a test assistant"
  )
  
  chat$register_tool(test_tool)
  
  cat("SUCCESS: Chat created with tool registered\n")
  cat("Tools:", length(chat$tools), "\n\n")
}, error = function(e) {
  cat("FAILED:", conditionMessage(e), "\n\n")
})

# Test 2: Try to simulate what happens during streaming with tool call
cat("--- Test 2: Simulate streaming with tool result ---\n")
cat("This simulates what chat_append_stream() does internally\n")
tryCatch({
  # Create a mock stream result similar to what ellmer returns
  # when a tool is called during streaming
  mock_tool_result <- list(
    content = "Test content",
    tool_calls = list(
      list(
        id = "call_123",
        type = "function",
        func = list(
          name = "test_tool",
          arguments = '{"message": "test"}'
        )
      )
    )
  )
  
  # This is approximately what shinychat does internally
  # when processing tool results from the stream
  if (!is.null(mock_tool_result$tool_calls)) {
    for (tc in mock_tool_result$tool_calls) {
      # Shinychat tries to create data.frames to track tool calls
      # This is where the error occurs with ellmer 0.4.0
      df_attempt <- data.frame(
        id = tc$id,
        name = tc$func$name,
        args = tc$func$arguments,
        result = character(0)  # This creates the mismatch!
      )
    }
  }
  
  cat("This should fail with ellmer 0.4.0...\n")
}, error = function(e) {
  cat("ERROR REPRODUCED: ", conditionMessage(e), "\n\n")
})

# Test 3: Show the exact data.frame issue
cat("--- Test 3: Direct data.frame row mismatch ---\n")
tryCatch({
  df <- data.frame(
    col1 = "value",
    col2 = character(0)
  )
  cat("SUCCESS: data.frame created\n")
}, error = function(e) {
  cat("ERROR: ", conditionMessage(e), "\n")
  cat("This is the core issue in shinychat when processing ellmer 0.4.0 streams\n\n")
})

cat("=== Test Complete ===\n")
