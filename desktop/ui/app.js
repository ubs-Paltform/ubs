(() => {
  "use strict";

  const locale = resolveLocale(navigator.languages || [navigator.language]);
  const messages = window.UBS_MESSAGES;
  const tauri = window.__TAURI__;
  const invoke = tauri?.core?.invoke;
  const openDialog = tauri?.dialog?.open;
  const listen = tauri?.event?.listen;
  const projectStore = window.UBS_PROJECT_STORE;
  const projectsKey = "ubs.saved-projects.v1";
  const selectedProjectKey = "ubs.selected-project.v1";
  const buildHistoryKey = "ubs.build-history.v1";
  const storage = (() => {
    try {
      return window.localStorage;
    } catch {
      return null;
    }
  })();
  const projects = [];
  const savedProjects = projectStore.load(storage, projectsKey);
  const buildHistory = projectStore.loadHistory(storage, buildHistoryKey);
  const logLines = [];
  let selectedProject = null;
  let running = false;
  let timer = null;
  let startedAt = 0;
  let copyFeedbackTimer = null;

  const elements = {
    chooseFolder: document.querySelector("#choose-folder"),
    projectPath: document.querySelector("#project-path"),
    projectBadge: document.querySelector("#project-badge"),
    projectChoice: document.querySelector("#project-choice"),
    projectList: document.querySelector("#project-list"),
    projectState: document.querySelector("#project-state"),
    currentProject: document.querySelector("#current-project"),
    currentProjectName: document.querySelector("#current-project-name"),
    currentProjectSymbol: document.querySelector("#current-project-symbol"),
    currentProjectType: document.querySelector("#current-project-type"),
    removeCurrentProject: document.querySelector("#remove-current-project"),
    buildHistory: document.querySelector("#build-history"),
    historyCount: document.querySelector("#history-count"),
    historyEmpty: document.querySelector("#history-empty"),
    versionBumps: [...document.querySelectorAll('input[name="version-bump"]')],
    jobs: [...document.querySelectorAll('input[name="jobs"]')],
    jobsCard: document.querySelector("#jobs-card"),
    cleanBuild: document.querySelector("#clean-build"),
    outputFieldset: document.querySelector("#output-fieldset"),
    outputHint: document.querySelector("#output-hint"),
    outputChecks: [...document.querySelectorAll("#output-fieldset input")],
    pipeline: [...document.querySelectorAll("#pipeline li")],
    runStatus: document.querySelector("#run-status"),
    startBuild: document.querySelector("#start-build"),
    cancelBuild: document.querySelector("#cancel-build"),
    buildLog: document.querySelector("#build-log"),
    buildResult: document.querySelector("#build-result"),
    copyLog: document.querySelector("#copy-log"),
    copyLogStatus: document.querySelector("#copy-log-status"),
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

  function projectName(path) {
    return path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || path;
  }

  function projectSymbol(type) {
    return type.slice(0, 2).toUpperCase();
  }

  function historyStatus(status) {
    const keys = {
      success: "historySuccess",
      failed: "historyFailed",
      cancelled: "historyCancelled"
    };
    return text(keys[status] || "historyFailed");
  }

  function settingsSummary(settings, type) {
    const normalized = projectStore.normalizeSettings(settings);
    const versionKeys = {
      none: "versionNone",
      build: "versionBuild",
      patch: "versionPatch",
      minor: "versionMinor",
      major: "versionMajor"
    };
    const outputs = normalized.outputs[0] === "auto"
      ? text("outputAuto")
      : normalized.outputs.map((output) => output.toUpperCase()).join("+");
    return [
      text(versionKeys[normalized.versionBump]),
      text(normalized.jobs === 1 ? "jobsSequential" : "jobsParallel"),
      normalized.clean ? text("cleanLabel") : null,
      type === "flutter" ? outputs : null
    ].filter(Boolean).join(" · ");
  }

  function renderHistory() {
    elements.buildHistory.replaceChildren();
    elements.historyCount.textContent = String(buildHistory.length);
    elements.historyEmpty.hidden = buildHistory.length > 0;
    buildHistory.forEach((record, index) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "history-item";
      button.dataset.index = String(index);
      button.dataset.status = record.status;
      button.classList.toggle("active", selectedProject?.path === record.path);
      button.setAttribute("aria-label", `${projectName(record.path)} · ${settingsSummary(record.settings, record.type)}`);
      if (record.builtAt) button.title = `${record.path}\n${record.builtAt}`;

      const title = document.createElement("span");
      title.className = "history-title";
      const name = document.createElement("strong");
      name.textContent = projectName(record.path);
      const status = document.createElement("span");
      status.className = "history-status";
      status.textContent = historyStatus(record.status);
      title.append(name, status);

      const summary = document.createElement("span");
      summary.className = "history-summary";
      summary.textContent = settingsSummary(record.settings, record.type);
      button.append(title, summary);
      elements.buildHistory.append(button);
    });
  }

  function rememberBuild(project, settings, status) {
    const next = projectStore.rememberBuild(buildHistory, project, settings, status);
    buildHistory.splice(0, buildHistory.length, ...next);
    projectStore.saveHistory(storage, buildHistoryKey, buildHistory);
    renderHistory();
  }

  function saveCurrentProject(project) {
    savedProjects.splice(0, savedProjects.length, ...(project ? [project] : []));
    projectStore.save(storage, projectsKey, savedProjects);
  }

  function applySelectedProject() {
    const isFlutter = selectedProject?.type === "flutter";
    elements.chooseFolder.hidden = Boolean(selectedProject);
    elements.currentProject.hidden = !selectedProject;
    elements.projectBadge.textContent = selectedProject?.type || text("notDetected");
    elements.projectBadge.classList.toggle("detected", Boolean(selectedProject));
    elements.currentProjectName.textContent = selectedProject ? projectName(selectedProject.path) : "";
    elements.currentProjectSymbol.textContent = selectedProject ? projectSymbol(selectedProject.type) : "--";
    elements.currentProjectType.textContent = selectedProject?.type || "";
    elements.projectPath.textContent = selectedProject?.path || "";
    if (selectedProject) {
      elements.removeCurrentProject.setAttribute("aria-label", text("removeProject", {
        name: projectName(selectedProject.path)
      }));
    }
    elements.outputFieldset.disabled = running || !isFlutter;
    elements.outputHint.textContent = text(isFlutter ? "outputsReady" : "outputsUnavailable");
    elements.startBuild.disabled = running || !selectedProject;
    projectStore.saveSelectedPath(storage, selectedProjectKey, selectedProject?.path);
    syncBuildModeVisibility();
    renderHistory();
    if (selectedProject) setPipeline("validate");
    else setPipeline(null);
  }

  function selectProject(project, announce = true, closeChoice = true) {
    selectedProject = project;
    if (closeChoice) elements.projectChoice.hidden = true;
    saveCurrentProject(project);
    applyBuildSettings(projectStore.latestSettings(buildHistory, project.path));
    applySelectedProject();
    if (announce) setProjectState(text("projectSelected", { name: projectName(project.path) }), "success");
  }

  function removeCurrentProject() {
    if (!selectedProject || running) return;
    const removed = selectedProject;
    selectedProject = null;
    projects.splice(0);
    elements.projectChoice.hidden = true;
    saveCurrentProject(null);
    applyBuildSettings(projectStore.normalizeSettings());
    applySelectedProject();
    setProjectState(text("projectRemoved", { name: projectName(removed.path) }), "success");
  }

  function selectedValue(inputs) {
    return inputs.find((input) => input.checked)?.value;
  }

  function currentBuildSettings() {
    return projectStore.normalizeSettings({
      versionBump: selectedValue(elements.versionBumps),
      jobs: Number(selectedValue(elements.jobs)),
      clean: elements.cleanBuild.checked,
      outputs: elements.outputChecks.filter((input) => input.checked).map((input) => input.value)
    });
  }

  function applyBuildSettings(settings) {
    const normalized = projectStore.normalizeSettings(settings);
    elements.versionBumps.forEach((input) => {
      input.checked = input.value === normalized.versionBump;
    });
    elements.jobs.forEach((input) => {
      input.checked = Number(input.value) === normalized.jobs;
    });
    elements.cleanBuild.checked = normalized.clean;
    elements.outputChecks.forEach((input) => {
      input.checked = normalized.outputs.includes(input.value);
    });
    syncBuildModeVisibility();
  }

  function syncBuildModeVisibility() {
    const outputCount = elements.outputChecks.filter((input) => input.checked && input.value !== "auto").length;
    const showBuildMode = selectedProject?.type === "flutter" && outputCount >= 2;
    elements.jobsCard.hidden = !showBuildMode;
    if (!showBuildMode) {
      elements.jobs.forEach((input) => {
        input.checked = input.value === "1";
      });
    }
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
    syncBuildModeVisibility();
  }

  function syncProject() {
    const project = projects[Number(elements.projectList.value)] || null;
    if (project) selectProject(project, false, false);
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
      selectedProject = null;
      applySelectedProject();
      elements.projectPath.textContent = root;
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
      saveCurrentProject(null);
      applySelectedProject();
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
    elements.copyLog.disabled = false;
  }

  function resetCopyFeedback() {
    if (copyFeedbackTimer) window.clearTimeout(copyFeedbackTimer);
    copyFeedbackTimer = null;
    elements.copyLog.className = "console-copy-button";
    elements.copyLog.textContent = text("copyLog");
    elements.copyLog.disabled = !elements.buildLog.textContent.trim();
    elements.copyLogStatus.textContent = "";
  }

  function showCopyFeedback(key, tone) {
    if (copyFeedbackTimer) window.clearTimeout(copyFeedbackTimer);
    const message = text(key);
    elements.copyLog.className = `console-copy-button ${tone}`;
    elements.copyLog.textContent = message;
    elements.copyLogStatus.textContent = message;
    copyFeedbackTimer = window.setTimeout(resetCopyFeedback, 1800);
  }

  async function writeClipboard(value) {
    if (navigator.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(value);
        return;
      } catch {
        // Fall through for webviews where Clipboard API permission is unavailable.
      }
    }
    const textarea = document.createElement("textarea");
    textarea.value = value;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.append(textarea);
    textarea.select();
    try {
      if (!document.execCommand("copy")) throw new Error("copy failed");
    } finally {
      textarea.remove();
    }
  }

  async function copyBuildLog() {
    const value = elements.buildLog.textContent;
    if (!value.trim()) return;
    try {
      await writeClipboard(value);
      showCopyFeedback("logCopied", "success");
    } catch {
      showCopyFeedback("logCopyFailed", "error");
    }
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
    [...elements.versionBumps, ...elements.jobs].forEach((input) => {
      input.disabled = value;
    });
    elements.cleanBuild.disabled = value;
    elements.projectList.disabled = value;
    elements.removeCurrentProject.disabled = value;
    elements.buildHistory.querySelectorAll("button").forEach((button) => {
      button.disabled = value;
    });
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
    const project = { ...selectedProject };
    const settings = currentBuildSettings();
    let historyResult = "failed";
    logLines.splice(0);
    elements.buildLog.textContent = "";
    resetCopyFeedback();
    elements.buildResult.replaceChildren();
    elements.runStatus.textContent = text("building");
    elements.runStatus.className = "run-status running";
    setPipeline("build");
    setRunning(true);
    try {
      const result = await invoke("run_build", {
        request: {
          project: project.path,
          versionBump: settings.versionBump,
          outputs: project.type === "flutter" ? settings.outputs.filter((output) => output !== "auto") : [],
          jobs: settings.jobs,
          clean: settings.clean,
          locale
        }
      });
      if (logLines.length === 0) {
        const fallback = [result.stdout, result.stderr].filter(Boolean).join("\n");
        if (fallback) {
          elements.buildLog.textContent = fallback;
          elements.copyLog.disabled = false;
        }
      }
      renderResult(result);
      historyResult = result.cancelled ? "cancelled" : result.success ? "success" : "failed";
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
      rememberBuild(project, settings, historyResult);
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
    renderHistory();
    const restoredPath = projectStore.selectedPath(storage, selectedProjectKey);
    const restored = savedProjects.find((project) => project.path === restoredPath) || savedProjects[0];
    if (restored) {
      selectProject(restored, false);
      setProjectState(text("projectSelected", { name: projectName(restored.path) }), "success");
    }
    elements.chooseFolder.addEventListener("click", chooseFolder);
    elements.removeCurrentProject.addEventListener("click", removeCurrentProject);
    elements.projectList.addEventListener("change", syncProject);
    elements.buildHistory.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-index]");
      if (!button || running) return;
      const record = buildHistory[Number(button.dataset.index)];
      if (!record) return;
      selectProject({ path: record.path, type: record.type });
    });
    elements.outputChecks.forEach((input) => {
      input.addEventListener("change", () => syncOutputChecks(input));
    });
    elements.startBuild.addEventListener("click", startBuild);
    elements.cancelBuild.addEventListener("click", cancelBuild);
    elements.copyLog.addEventListener("click", copyBuildLog);
    if (listen) await listen("build-log", ({ payload }) => appendLog(payload));
    if (!invoke || !openDialog) setProjectState(text("desktopOnly"), "error");
  }

  initialize().catch((error) => setProjectState(String(error), "error"));
})();
