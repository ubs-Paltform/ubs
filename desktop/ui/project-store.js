const versionBumps = new Set(["none", "build", "patch", "minor", "major"]);
const outputTypes = new Set(["appbundle", "apk", "ipa", "pkg", "web"]);
const historyStatuses = new Set(["success", "failed", "cancelled"]);

function normalizeSettings(settings) {
  const explicitOutputs = Array.isArray(settings?.outputs)
    ? [...new Set(settings.outputs.filter((output) => outputTypes.has(output)))]
    : [];
  return {
    versionBump: versionBumps.has(settings?.versionBump) ? settings.versionBump : "none",
    jobs: settings?.jobs === 1 ? 1 : 0,
    clean: settings?.clean === true,
    outputs: explicitOutputs.length > 0 ? explicitOutputs : ["appbundle", "ipa"]
  };
}

function normalizeHistory(history) {
  const unique = new Map();
  (Array.isArray(history) ? history : []).forEach((record) => {
    if (
      record
      && typeof record.path === "string"
      && record.path.length > 0
      && typeof record.type === "string"
      && record.type.length > 0
      && !unique.has(record.path)
    ) {
      unique.set(record.path, {
        path: record.path,
        type: record.type,
        settings: normalizeSettings(record.settings),
        status: historyStatuses.has(record.status) ? record.status : "failed",
        builtAt: typeof record.builtAt === "string" ? record.builtAt : ""
      });
    }
  });
  return [...unique.values()];
}

window.UBS_PROJECT_STORE = Object.freeze({
  load(storage, key) {
    try {
      const parsed = JSON.parse(storage?.getItem(key) || "[]");
      return this.merge(Array.isArray(parsed) ? parsed : [], []);
    } catch {
      return [];
    }
  },

  save(storage, key, projects) {
    try {
      storage?.setItem(key, JSON.stringify(projects));
    } catch {
      // 영구 저장소를 쓸 수 없어도 현재 세션의 빌드는 유지한다.
    }
  },

  merge(recent, saved) {
    const unique = new Map();
    [...recent, ...saved].forEach((project) => {
      if (
        project
        && typeof project.path === "string"
        && project.path.length > 0
        && typeof project.type === "string"
        && project.type.length > 0
        && !unique.has(project.path)
      ) {
        unique.set(project.path, { path: project.path, type: project.type });
      }
    });
    return [...unique.values()];
  },

  selectedPath(storage, key) {
    try {
      return storage?.getItem(key) || null;
    } catch {
      return null;
    }
  },

  saveSelectedPath(storage, key, path) {
    try {
      if (path) storage?.setItem(key, path);
      else storage?.removeItem(key);
    } catch {
      // 선택 복원이 불가능해도 빌드 기능은 유지한다.
    }
  },

  normalizeSettings,

  loadHistory(storage, key) {
    try {
      return normalizeHistory(JSON.parse(storage?.getItem(key) || "[]"));
    } catch {
      return [];
    }
  },

  saveHistory(storage, key, history) {
    try {
      storage?.setItem(key, JSON.stringify(normalizeHistory(history)));
    } catch {
      // 기록 저장이 불가능해도 현재 빌드는 유지한다.
    }
  },

  rememberBuild(history, project, settings, status, builtAt = new Date().toISOString()) {
    if (!project?.path || !project?.type) return normalizeHistory(history);
    return normalizeHistory([{
      path: project.path,
      type: project.type,
      settings: normalizeSettings(settings),
      status: historyStatuses.has(status) ? status : "failed",
      builtAt
    }, ...history.filter((record) => record?.path !== project.path)]);
  },

  latestSettings(history, path) {
    const match = normalizeHistory(history).find((record) => record.path === path);
    return normalizeSettings(match?.settings);
  }
});
