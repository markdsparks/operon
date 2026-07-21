# Python and Ollama examples

From the repository root, with Ollama running:

```bash
PYTHONPATH=sdk/python/src python3 examples/python-ollama/wrap_ollama.py
PYTHONPATH=sdk/python/src python3 examples/python-ollama/typed_decision.py
```

The JSON schema can also be passed to the CLI with `--output-schema`.
