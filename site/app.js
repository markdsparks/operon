const copyButton = document.querySelector("[data-copy]");
const code = `from operon import Operon, SkillRegistry

runtime = Operon.wrap(
  provider=your_local_model,
  skills=SkillRegistry(app_skills),
  memory=local_memory,
)

result = runtime.run(
  "Continue with the last result",
  session_artifacts=current_context,
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
