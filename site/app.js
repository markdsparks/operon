const copyButton = document.querySelector("[data-copy]");
const code = `from operon import Operon, LocalDocuments

runtime = Operon.wrap(
  model=your_local_model,
  grounding=LocalDocuments("./app-facts"),
)

result = runtime.run("Answer using local facts")
print(result.answer, result.sources)`;

copyButton?.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(code);
    copyButton.textContent = "Copied ✓";
  } catch {
    copyButton.textContent = "Select code";
  }
  window.setTimeout(() => { copyButton.textContent = "Copy"; }, 1800);
});
