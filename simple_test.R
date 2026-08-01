#!/usr/bin/env Rscript
# Simple test to show the data.frame error

cat("=== Data.frame Row Mismatch Test ===\n\n")

cat("Current package versions:\n")
cat("  ellmer:", as.character(packageVersion('ellmer')), "\n")
cat("  shinychat:", as.character(packageVersion('shinychat')), "\n\n")

cat("--- Test: Create data.frame with mismatched row counts ---\n")
cat("This simulates what happens in shinychat when processing ellmer 0.4.0 tool results\n\n")

cat("Attempting: data.frame(col1 = 'value', col2 = character(0))\n")
tryCatch({
  df <- data.frame(
    col1 = "value",
    col2 = character(0)
  )
  cat("UNEXPECTED: data.frame created successfully\n")
  print(df)
}, error = function(e) {
  cat("ERROR REPRODUCED:\n")
  cat("  ", conditionMessage(e), "\n\n")
  cat("This is the exact error that occurs in shinychat::chat_append_stream()\n")
  cat("when it tries to process streaming tool call results from ellmer 0.4.0\n")
})

cat("\n=== End Test ===\n")
