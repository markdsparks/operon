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

const exampleTabs = [...document.querySelectorAll("[data-example-tab]")];
const examplePanels = [...document.querySelectorAll("[data-example-panel]")];

function selectExample(selectedTab, moveFocus = false) {
  const selectedID = selectedTab.dataset.exampleTab;
  exampleTabs.forEach((tab) => {
    const isSelected = tab === selectedTab;
    tab.setAttribute("aria-selected", String(isSelected));
    tab.tabIndex = isSelected ? 0 : -1;
  });
  examplePanels.forEach((panel) => {
    panel.hidden = panel.dataset.examplePanel !== selectedID;
  });
  if (moveFocus) selectedTab.focus();
}

exampleTabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectExample(tab));
  tab.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    let nextIndex = index;
    if (event.key === "ArrowLeft") nextIndex = (index - 1 + exampleTabs.length) % exampleTabs.length;
    if (event.key === "ArrowRight") nextIndex = (index + 1) % exampleTabs.length;
    if (event.key === "Home") nextIndex = 0;
    if (event.key === "End") nextIndex = exampleTabs.length - 1;
    selectExample(exampleTabs[nextIndex], true);
  });
});
