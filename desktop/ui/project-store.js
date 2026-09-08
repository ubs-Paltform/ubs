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
  }
});
