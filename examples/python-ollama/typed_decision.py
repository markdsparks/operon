from operon import LocalDocuments, OpenAICompatibleProvider, Operon


provider = OpenAICompatibleProvider(
    model="qwen3:4b",
    base_url="http://127.0.0.1:11434/v1",
)

runtime = Operon.wrap(
    provider,
    grounding=LocalDocuments("benchmarks/fixtures/meal_expense"),
    output_schema={
        "type": "object",
        "properties": {
            "decision": {
                "type": "string",
                "enum": ["full", "partial", "deny"],
                "description": "Whether all, some, or none of the request is allowed.",
            },
            "reimbursable_amount_usd": {
                "type": "number",
                "minimum": 0,
                "description": "Food plus tax and tip that policy permits; exclude alcohol.",
            },
            "excluded_items": {
                "type": "array",
                "items": {"type": "string"},
            },
        },
        "required": ["decision", "reimbursable_amount_usd", "excluded_items"],
        "additionalProperties": False,
    },
)

response = runtime.run(
    "An employee's individual dinner has $68 of food plus a separate $20 alcoholic drink. "
    "The receipt is itemized. Determine exactly how much is reimbursable."
)

print(response.answer)
print(response.output)
