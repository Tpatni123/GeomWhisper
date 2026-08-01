library(ellmer)
chat <- chat_openai(model='gpt-4o-mini', base_url='https://models.inference.ai.azure.com', api_key=Sys.getenv('GITHUB_TOKEN'))
cb <- function(x) cat(x)
chat$stream_async('hello', echo='text')
