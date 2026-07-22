const copyButton = document.querySelector("[data-copy]");
const code = `from operon import Operon

# Start with the model already in your app
runtime = Operon.wrap(your_existing_model)
result = runtime.run("Help me plan my day")

# Add capabilities without replacing the model
runtime = Operon.wrap(
  your_existing_model,
  grounding=local_knowledge,
  skills=app_skills,
  memory=local_memory,
)
print(result.answer, result.trace.events)`;

copyButton?.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(code);
    copyButton.textContent = "Copied ✓";
  } catch {
    copyButton.textContent = "Select code";
  }
  window.setTimeout(() => { copyButton.textContent = "Copy"; }, 1800);
});
