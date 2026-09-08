#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

node --check desktop/ui/catalog.js
node --check desktop/ui/project-store.js
node --check desktop/ui/app.js

node <<'NODE'
const fs = require("node:fs");
const vm = require("node:vm");
const context = { window: {} };
vm.runInNewContext(fs.readFileSync("desktop/ui/catalog.js", "utf8"), context);
const catalog = context.window.UBS_MESSAGES;
const locales = ["ko", "en", "ja", "zh"];
for (const locale of locales) {
  if (!catalog[locale]) throw new Error(`missing locale: ${locale}`);
}
const expected = Object.keys(catalog.en).sort().join("\n");
for (const locale of locales) {
  const actual = Object.keys(catalog[locale]).sort().join("\n");
  if (actual !== expected) throw new Error(`catalog key mismatch: ${locale}`);
}
NODE

node <<'NODE'
const fs = require("node:fs");
const vm = require("node:vm");
const context = { window: {} };
vm.runInNewContext(fs.readFileSync("desktop/ui/project-store.js", "utf8"), context);
const store = context.window.UBS_PROJECT_STORE;
const values = new Map();
const storage = {
  getItem: (key) => values.get(key) ?? null,
  setItem: (key, value) => values.set(key, value),
  removeItem: (key) => values.delete(key)
};
const saved = [{ path: "/old", type: "tauri" }, { path: "/same", type: "flutter" }];
const recent = [{ path: "/same", type: "tauri" }, { path: "/new", type: "flutter" }];
const merged = store.merge(recent, saved);
if (JSON.stringify(merged) !== JSON.stringify([
  { path: "/same", type: "tauri" },
  { path: "/new", type: "flutter" },
  { path: "/old", type: "tauri" }
])) throw new Error("project merge contract failed");
store.save(storage, "projects", merged);
if (JSON.stringify(store.load(storage, "projects")) !== JSON.stringify(merged)) throw new Error("project load contract failed");
store.saveSelectedPath(storage, "selected", "/new");
if (store.selectedPath(storage, "selected") !== "/new") throw new Error("selection restore contract failed");
values.set("projects", "{");
if (store.load(storage, "projects").length !== 0) throw new Error("corrupt storage contract failed");

const safe = store.normalizeSettings({ versionBump: "bogus", jobs: 8, clean: "yes", outputs: ["auto", "apk", "apk", "bad"] });
if (JSON.stringify(safe) !== JSON.stringify({
  versionBump: "none", jobs: 0, clean: false, outputs: ["apk"]
})) throw new Error("settings normalization contract failed");
const flutter = { path: "/apps/canary", type: "flutter" };
let history = store.rememberBuild([], flutter, {
  versionBump: "patch", jobs: 1, clean: true, outputs: ["appbundle", "web"]
}, "success", "2026-09-08T01:00:00.000Z");
history = store.rememberBuild(history, flutter, {
  versionBump: "build", jobs: 0, clean: false, outputs: ["ipa"]
}, "failed", "2026-09-08T02:00:00.000Z");
if (history.length !== 1 || history[0].status !== "failed") throw new Error("latest history contract failed");
if (JSON.stringify(store.latestSettings(history, flutter.path)) !== JSON.stringify({
  versionBump: "build", jobs: 0, clean: false, outputs: ["ipa"]
})) throw new Error("history settings restore contract failed");
store.saveHistory(storage, "history", history);
if (JSON.stringify(store.loadHistory(storage, "history")) !== JSON.stringify(history)) throw new Error("history persistence contract failed");
values.set("history", "{");
if (store.loadHistory(storage, "history").length !== 0) throw new Error("corrupt history contract failed");
NODE

python3 <<'PY'
import json
from html.parser import HTMLParser
from pathlib import Path

root = Path("desktop")
icon = (root / "src-tauri/icons/icon.png").read_bytes()
assert icon[:8] == b"\x89PNG\r\n\x1a\n"
assert icon[24] == 8 and icon[25] == 6, "Tauri requires an 8-bit RGBA icon"

config = json.loads((root / "src-tauri/tauri.conf.json").read_text(encoding="utf-8"))
assert config["build"]["frontendDist"] == "../ui"
assert config["app"]["withGlobalTauri"] is True
csp = config["app"]["security"]["csp"]
assert "unsafe-inline" not in json.dumps(csp)
assert "unsafe-eval" not in json.dumps(csp)
assert set(config["bundle"]["resources"].values()) >= {
    "ubs-runtime/build.sh", "ubs-runtime/scripts/", "ubs-runtime/templates/", "ubs-runtime/VERSION"
}
assert config["bundle"]["macOS"]["signingIdentity"] == "-"

capability = json.loads((root / "src-tauri/capabilities/default.json").read_text(encoding="utf-8"))
assert capability["windows"] == ["main"]
assert set(capability["permissions"]) == {"core:event:default", "dialog:allow-open"}

class Assets(HTMLParser):
    def __init__(self):
        super().__init__()
        self.inline_scripts = 0
        self.inline_styles = 0
    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "script" and "src" not in values:
            self.inline_scripts += 1
        if tag == "style":
            self.inline_styles += 1

html = (root / "ui/index.html").read_text(encoding="utf-8")
parser = Assets()
parser.feed(html)
assert parser.inline_scripts == 0
assert parser.inline_styles == 0
assert '<select id="version-bump">' not in html
assert '<select id="jobs">' not in html
assert html.count('name="version-bump"') == 5
assert html.count('name="jobs"') == 2
assert html.count('name="version-bump" value="none" checked') == 1
assert html.count('name="jobs" value="0" checked') == 1
assert 'data-i18n="jobsSequential"' in html
assert 'data-i18n="jobsParallel"' in html
assert '<h1' not in html
for removed_header_key in ('data-i18n="eyebrow"', 'data-i18n="title"', 'data-i18n="subtitle"'):
    assert removed_header_key not in html
for current_project_contract in (
    'id="choose-folder"', 'id="current-project"', 'id="current-project-name"',
    'id="current-project-type"', 'id="remove-current-project"'
):
    assert current_project_contract in html
for removed_library_contract in ('id="saved-projects"', 'id="saved-count"', 'id="saved-empty"'):
    assert removed_library_contract not in html
assert 'id="jobs-card" class="option-card choice-card jobs-card" hidden' in html
assert 'class="execution-grid"' in html
assert html.index('name="version-bump"') < html.index('id="output-fieldset"') < html.index('id="jobs-card"') < html.index('id="clean-build"')
for history_contract in ('id="build-history"', 'id="history-count"', 'id="history-empty"'):
    assert history_contract in html

frontend = "\n".join(path.read_text(encoding="utf-8") for path in (root / "ui").iterdir())
assert "https://" not in frontend and "http://" not in frontend

rust = (root / "src-tauri/src/main.rs").read_text(encoding="utf-8")
for guardrail in ('"--non-interactive"', '"--no-publish"', "slot.active", "terminate_process_tree", "RunEvent::ExitRequested"):
    assert guardrail in rust

app = (root / "ui/app.js").read_text(encoding="utf-8")
for app_contract in ("projectStore", "saveCurrentProject", "syncBuildModeVisibility", "outputCount >= 2", "canonical_directory"):
    assert app_contract in app or app_contract in rust
for live_log_contract in ('"--verbose"', '"PYTHONUNBUFFERED"', '"UBS_FLUTTER_PARALLEL"'):
    assert live_log_contract in rust
print("desktop GUI contract valid")
PY
