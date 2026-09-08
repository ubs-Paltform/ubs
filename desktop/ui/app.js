(() => {
  "use strict";

  const locale = resolveLocale(navigator.languages || [navigator.language]);
  const messages = window.UBS_MESSAGES;
  const tauri = window.__TAURI__;
  const invoke = tauri?.core?.invoke;
  const openDialog = tauri?.dialog?.open;
  const listen = tauri?.event?.listen;
  const projects = [];
  const logLines = [];
  let selectedProject = null;
  let running = false;
  let timer = null;
  let startedAt = 0;

  const elements = {
    chooseFolder: document.querySelector("#choose-folder"),
    projectPath: document.querySelector("#project-path"),
    projectBadge: document.querySelector("#project-badge"),
    projectChoice: document.querySelector("#project-choice"),
    projectList: document.querySelector("#project-list"),
    projectState: document.querySelector("#project-state"),
    versionBump: document.querySelector("#version-bump"),
    jobs: document.querySelector("#jobs"),
    cleanBuild: document.querySelector("#clean-build"),
    outputFieldset: document.querySelector("#output-fieldset"),
    outputHint: document.querySelector("#output-hint"),
    outputChecks: [...document.querySelectorAll("#output-fieldset input")],
    pipeline: [...document.querySelectorAll("#pipeline li")],
    runStatus: document.querySelector("#run-status"),
    startBuild: document.querySelector("#start-build"),
    cancelBuild: document.querySelector("#cancel-build"),
    consolePanel: document.querySelector("#console-panel"),
    buildLog: document.querySelector("#build-log"),
    buildResult: document.querySelector("#build-result"),
    elapsed: document.querySelector("#elapsed"),
    localeName: document.querySelector("#locale-name")
  };

  function resolveLocale(languages) {
    const language = languages.find(Boolean)?.toLowerCase() || "en";
    if (language.startsWith("ko")) return "ko";
    if (language.startsWith("ja")) return "ja";
    if (language.startsWith("zh")) return "zh";
    return "en";
  }

  function text(key, values = {}) {
    let value = messages[locale]?.[key] || messages.en[key] || key;
    for (const [name, replacement] of Object.entries(values)) {
      value = value.replace(`{${name}}`, String(replacement));
    }
    return value;
  }

  function applyLocale() {
    document.documentElement.lang = locale;
    document.querySelectorAll("[data-i18n]").forEach((element) => {
      element.textContent = text(element.dataset.i18n);
    });
    elements.localeName.textContent = text("language");
  }

  function setProjectState(message, tone = "neutral") {
    elements.projectState.textContent = message;
    elements.projectState.dataset.tone = tone;
  }

  function setPipeline(activeStage, failed = false) {
    const order = ["detect", "validate", "build", "package", "done"];
    const activeIndex = order.indexOf(activeStage);
    elements.pipeline.forEach((item, index) => {
      item.className = "";
      if (activeIndex < 0) return;
      if (index < activeIndex) item.classList.add("complete");
      if (index === activeIndex) item.classList.add(failed ? "failed" : "active");
    });
  }

  function selectedOutputs() {
    return elements.outputChecks
      .filter((input) => input.checked && input.value !== "auto")
      .map((input) => input.value);
  }

  function syncOutputChecks(changed) {
    const auto = elements.outputChecks.find((input) => input.value === "auto");
    const explicit = elements.outputChecks.filter((input) => input.value !== "auto");
    if (changed.value === "auto" && changed.checked) {
      explicit.forEach((input) => { input.checked = false; });
    } else if (changed.value !== "auto" && changed.checked) {
      auto.checked = false;
    }
    if (!elements.outputChecks.some((input) => input.checked)) auto.checked = true;
  }

  function syncProject() {
    selectedProject = projects[Number(elements.projectList.value)] || null;
    const isFlutter = selectedProject?.type === "flutter";
    elements.projectBadge.textContent = selectedProject?.type || text("notDetected");
    elements.projectBadge.classList.toggle("detected", Boolean(selectedProject));
    elements.outputFieldset.disabled = !isFlutter;
    elements.outputHint.textContent = text(isFlutter ? "outputsReady" : "outputsUnavailable");
    elements.startBuild.disabled = !selectedProject || running;
    if (selectedProject) setPipeline("validate");
  }

  async function chooseFolder() {
    if (!openDialog || !invoke) {
      setProjectState(text("desktopOnly"), "error");
      return;
    }
    try {
      const root = await openDialog({
        directory: true,
        multiple: false,
        title: text("chooseDialog")
      });
      if (!root) return;
      elements.projectPath.textContent = root;
      elements.projectBadge.textContent = text("notDetected");
      elements.projectBadge.classList.remove("detected");
      elements.startBuild.disabled = true;
      elements.projectChoice.hidden = true;
      setProjectState(text("detecting"));
      setPipeline("detect");
      const detected = await invoke("detect_projects", { root });
      projects.splice(0, projects.length, ...(Array.isArray(detected) ? detected : []));
      renderProjects();
    } catch {
      projects.splice(0);
      selectedProject = null;
      elements.projectChoice.hidden = true;
      elements.startBuild.disabled = true;
      setPipeline("detect", true);
      setProjectState(text("detectFailed"), "error");
    }
  }

  function renderProjects() {
    elements.projectList.replaceChildren();
    projects.forEach((project, index) => {
      const option = document.createElement("option");
      option.value = String(index);
      option.textContent = `[${project.type}] ${project.path}`;
      elements.projectList.append(option);
    });
    if (projects.length === 0) {
      selectedProject = null;
      elements.projectChoice.hidden = true;
      elements.projectBadge.textContent = text("notDetected");
      setProjectState(text("noProjects"), "error");
      setPipeline("detect", true);
      return;
    }
    elements.projectChoice.hidden = projects.length === 1;
    elements.projectList.value = "0";
    setProjectState(
      projects.length === 1
        ? text("oneProject")
        : text("manyProjects", { count: projects.length }),
      "success"
    );
    syncProject();
  }

  function appendLog(payload) {
    const prefix = payload?.stream === "stderr" ? "! " : "› ";
    const line = `${prefix}${payload?.line || ""}`;
    logLines.push(line);
    if (logLines.length > 300) logLines.shift();
    elements.buildLog.textContent = logLines.join("\n");
    elements.buildLog.scrollTop = elements.buildLog.scrollHeight;
  }

  function updateElapsed() {
    const seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    const minutes = String(Math.floor(seconds / 60)).padStart(2, "0");
    const remainder = String(seconds % 60).padStart(2, "0");
    elements.elapsed.textContent = `${minutes}:${remainder}`;
  }

  function setRunning(value) {
    running = value;
    elements.chooseFolder.disabled = value;
    elements.versionBump.disabled = value;
    elements.jobs.disabled = value;
    elements.cleanBuild.disabled = value;
    elements.projectList.disabled = value;
    elements.outputFieldset.disabled = value || selectedProject?.type !== "flutter";
    elements.startBuild.hidden = value;
    elements.startBuild.disabled = value || !selectedProject;
    elements.cancelBuild.hidden = !value;
    if (value) {
      startedAt = Date.now();
      updateElapsed();
      timer = window.setInterval(updateElapsed, 1000);
    } else if (timer) {
      window.clearInterval(timer);
      timer = null;
    }
  }

  function renderResult(result) {
    const artifacts = result?.report?.results?.flatMap((item) => item.artifacts || []) || [];
    elements.buildResult.replaceChildren();
    const summary = document.createElement("strong");
    summary.textContent = result.cancelled
      ? text("cancelled")
      : result.success
        ? text("succeeded")
        : text("failed", { code: result.exitCode ?? "?" });
    summary.className = result.success ? "result-success" : "result-error";
    elements.buildResult.append(summary);

    const artifactSummary = document.createElement("span");
    artifactSummary.textContent = artifacts.length
      ? text("artifacts", { count: artifacts.length })
      : text("noArtifacts");
    elements.buildResult.append(artifactSummary);
    for (const artifact of artifacts.slice(0, 8)) {
      const path = typeof artifact === "string" ? artifact : artifact.path;
      if (!path) continue;
      const item = document.createElement("code");
      item.textContent = path;
      elements.buildResult.append(item);
    }
  }

  async function startBuild() {
    if (!invoke || !selectedProject || running) return;
    logLines.splice(0);
    elements.buildLog.textContent = "";
    elements.buildResult.replaceChildren();
    elements.consolePanel.hidden = false;
    elements.runStatus.textContent = text("building");
    elements.runStatus.className = "run-status running";
    setPipeline("build");
    setRunning(true);
    try {
      const result = await invoke("run_build", {
        request: {
          project: selectedProject.path,
          versionBump: elements.versionBump.value,
          outputs: selectedProject.type === "flutter" ? selectedOutputs() : [],
          jobs: Number(elements.jobs.value),
          clean: elements.cleanBuild.checked,
          locale
        }
      });
      if (logLines.length === 0) {
        const fallback = [result.stdout, result.stderr].filter(Boolean).join("\n");
        if (fallback) elements.buildLog.textContent = fallback;
      }
      renderResult(result);
      if (result.success) {
        elements.runStatus.textContent = text("succeeded");
        elements.runStatus.className = "run-status success";
        setPipeline("done");
        elements.pipeline.forEach((item) => item.className = "complete");
      } else {
        elements.runStatus.textContent = result.cancelled ? text("cancelled") : text("failed", { code: result.exitCode ?? "?" });
        elements.runStatus.className = "run-status error";
        setPipeline("build", true);
      }
    } catch {
      elements.runStatus.textContent = text("buildError");
      elements.runStatus.className = "run-status error";
      setPipeline("build", true);
      appendLog({ stream: "stderr", line: text("buildError") });
    } finally {
      setRunning(false);
    }
  }

  async function cancelBuild() {
    if (!invoke || !running) return;
    elements.cancelBuild.disabled = true;
    elements.runStatus.textContent = text("cancelling");
    try {
      await invoke("cancel_build");
    } finally {
      elements.cancelBuild.disabled = false;
    }
  }

  async function initialize() {
    applyLocale();
    setPipeline(null);
    elements.chooseFolder.addEventListener("click", chooseFolder);
    elements.projectList.addEventListener("change", syncProject);
    elements.outputChecks.forEach((input) => {
      input.addEventListener("change", () => syncOutputChecks(input));
    });
    elements.startBuild.addEventListener("click", startBuild);
    elements.cancelBuild.addEventListener("click", cancelBuild);
    if (listen) await listen("build-log", ({ payload }) => appendLog(payload));
    if (!invoke || !openDialog) setProjectState(text("desktopOnly"), "error");
  }

  initialize().catch((error) => setProjectState(String(error), "error"));
})();
