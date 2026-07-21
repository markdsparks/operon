from operon import LocalDocuments, OpenAICompatibleProvider, Operon


provider = OpenAICompatibleProvider(
    model="qwen3:4b",
    base_url="http://127.0.0.1:11434/v1",
)

runtime = Operon.wrap(
    provider,
    grounding=LocalDocuments("examples/python-ollama/documents"),
)

response = runtime.run("Which policy applies to this request, and why?")
print(response.answer)
for source in response.sources:
    print(f"[{source.id}] {source.path}")
