#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/bin" "$FIXTURE/android/app" "$FIXTURE/android/gradle" \
  "$FIXTURE/mono/apps/child" "$FIXTURE/node" "$FIXTURE/workspace/apps/a" \
  "$FIXTURE/tauri-mixed/src-tauri" "$FIXTURE/tauri-nested/src-tauri" \
  "$FIXTURE/tauri-nested/frontend"

# Version Catalog plugin alias도 Android application으로 감지하고 bundleRelease를 선택한다.
printf '%s\n' 'pluginManagement {}' > "$FIXTURE/android/settings.gradle.kts"
printf '%s\n' '[plugins]' \
  'android-application = { id = "com.android.application", version = "8.7.0" }' \
  > "$FIXTURE/android/gradle/libs.versions.toml"
printf '%s\n' 'plugins { alias(libs.plugins.android.application) }' \
  'android { namespace = "dev.example" }' > "$FIXTURE/android/app/build.gradle.kts"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$UBS_TEST_LOG"' \
  > "$FIXTURE/android/gradlew"
chmod +x "$FIXTURE/android/gradlew"

ANDROID_TYPE="$("$ROOT/build.sh" detect --json "$FIXTURE/android" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["type"])')"
[ "$ANDROID_TYPE" = android ] || { echo "Version Catalog Android 감지 실패: $ANDROID_TYPE" >&2; exit 1; }
UBS_TEST_LOG="$FIXTURE/gradle.log" "$ROOT/build.sh" build --project "$FIXTURE/android"
grep -Fqx 'bundleRelease' "$FIXTURE/gradle.log" || {
  echo "Python Gradle adapter가 bundleRelease를 선택하지 않았습니다." >&2
  exit 1
}

# Node adapter는 dependency 입력이 같으면 두 번째 install을 생략한다.
printf '%s\n' '{"scripts":{"build":"node build.js"}}' > "$FIXTURE/node/package.json"
printf '%s\n' '{"lockfileVersion":3,"packages":{}}' > "$FIXTURE/node/package-lock.json"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "$UBS_TEST_LOG"' \
  > "$FIXTURE/bin/npm"
chmod +x "$FIXTURE/bin/npm"
PATH="$FIXTURE/bin:$PATH" UBS_TEST_LOG="$FIXTURE/node.log" \
  "$ROOT/build.sh" build --project "$FIXTURE/node"
PATH="$FIXTURE/bin:$PATH" UBS_TEST_LOG="$FIXTURE/node.log" \
  "$ROOT/build.sh" build --project "$FIXTURE/node"
printf '%s\n' 'legacy-peer-deps=true' > "$FIXTURE/node/.npmrc"
PATH="$FIXTURE/bin:$PATH" UBS_TEST_LOG="$FIXTURE/node.log" \
  "$ROOT/build.sh" build --project "$FIXTURE/node"
[ "$(grep -Fxc 'ci --no-fund --no-audit' "$FIXTURE/node.log")" -eq 2 ] || {
  echo "Node dependency install cache가 중복 install을 제거하지 못했습니다." >&2
  exit 1
}
[ "$(grep -Fxc 'run build' "$FIXTURE/node.log")" -eq 3 ] || {
  echo "Node build 실행 횟수가 예상과 다릅니다." >&2
  exit 1
}

# --all 계획과 실제 dry-run은 루트와 하위 프로젝트를 같은 집합으로 선택한다.
printf '%s\n' '{"scripts":{"build":"node root.js"}}' > "$FIXTURE/mono/package.json"
printf '%s\n' '{"scripts":{"build":"node child.js"}}' > "$FIXTURE/mono/apps/child/package.json"
PLAN_JSON="$("$ROOT/build.sh" plan --json --all "$FIXTURE/mono")"
printf '%s' "$PLAN_JSON" | python3 -c '
import json, os, sys
items = json.load(sys.stdin)
assert len(items) == 2
assert all(item["adapter"] == "scripts/ubs.py#node" for item in items)
expected_jobs = max(1, min(4, ((os.cpu_count() or 1) + 1) // 2))
assert all(item["options"]["jobs"] == expected_jobs for item in items)
assert all(item["options"]["install_mode"] == "auto" for item in items)
assert all(item["options"]["package_manager"] == "npm" for item in items)
'
PARALLEL_DRY_RUN="$(UBS_LANG=ko "$ROOT/build.sh" build --all --dry-run --jobs 2 "$FIXTURE/mono")"
printf '%s\n' "$PARALLEL_DRY_RUN" | grep -Fq '전체: 2' || {
  echo "병렬 dry-run 프로젝트 집합이 계획과 다릅니다." >&2
  exit 1
}

if "$ROOT/build.sh" --dry-run --jobs 0 "$FIXTURE/mono" >/dev/null 2>&1; then
  echo "0개의 병렬 job을 허용했습니다." >&2
  exit 1
fi

# workspace child는 루트 package manager/lockfile을 사용하고 같은 실행 그룹으로 직렬화한다.
printf '%s\n' '{"packageManager":"pnpm@9.15.0","workspaces":["apps/*"],"scripts":{"build":"pnpm -r build"}}' \
  > "$FIXTURE/workspace/package.json"
printf '%s\n' 'lockfileVersion: 9' > "$FIXTURE/workspace/pnpm-lock.yaml"
printf '%s\n' '{"scripts":{"build":"node build.js"}}' > "$FIXTURE/workspace/apps/a/package.json"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "--version" ]; then echo 9.15.0; exit 0; fi' \
  'printf "%s|%s\n" "$PWD" "$*" >> "$UBS_TEST_LOG"' > "$FIXTURE/bin/pnpm"
chmod +x "$FIXTURE/bin/pnpm"
PATH="$FIXTURE/bin:$PATH" UBS_TEST_LOG="$FIXTURE/pnpm.log" \
  "$ROOT/build.sh" build --project "$FIXTURE/workspace/apps/a"
grep -Fq "$FIXTURE/workspace|install --frozen-lockfile" "$FIXTURE/pnpm.log" || {
  echo "workspace root에서 pnpm install을 실행하지 않았습니다." >&2
  exit 1
}
grep -Fq "$FIXTURE/workspace/apps/a|run build" "$FIXTURE/pnpm.log" || {
  echo "workspace child build 위치가 잘못됐습니다." >&2
  exit 1
}
WORKSPACE_PLAN="$(PATH="$FIXTURE/bin:$PATH" "$ROOT/build.sh" plan --json --all --jobs 2 "$FIXTURE/workspace")"
printf '%s' "$WORKSPACE_PLAN" | python3 -c '
import json, sys
items = json.load(sys.stdin)
assert len(items) == 2
assert {item["options"]["package_manager"] for item in items} == {"pnpm"}
assert len({item["options"]["execution_group"] for item in items}) == 1
'

# legacy Tauri Node cache도 workspace 하위 package.json과 manager config 변경을 해시에 포함한다.
LEGACY_DIGEST_BEFORE="$(
  cd "$FIXTURE/workspace"
  # shellcheck source=../scripts/lib/node-package-manager.sh
  source "$ROOT/scripts/lib/node-package-manager.sh"
  NODE_PM=pnpm
  node_dependency_digest | node_dependency_sha256
)"
printf '%s\n' '{"scripts":{"build":"node changed.js"}}' > "$FIXTURE/workspace/apps/a/package.json"
LEGACY_DIGEST_AFTER="$(
  cd "$FIXTURE/workspace"
  # shellcheck source=../scripts/lib/node-package-manager.sh
  source "$ROOT/scripts/lib/node-package-manager.sh"
  NODE_PM=pnpm
  node_dependency_digest | node_dependency_sha256
)"
[ "$LEGACY_DIGEST_BEFORE" != "$LEGACY_DIGEST_AFTER" ] || {
  echo "legacy Node dependency hash가 workspace package.json 변경을 놓쳤습니다." >&2
  exit 1
}
LEGACY_CONFIG_BEFORE="$LEGACY_DIGEST_AFTER"
printf '%s\n' 'strict-peer-dependencies=false' > "$FIXTURE/workspace/.npmrc"
LEGACY_CONFIG_AFTER="$(
  cd "$FIXTURE/workspace"
  source "$ROOT/scripts/lib/node-package-manager.sh"
  NODE_PM=pnpm
  node_dependency_digest | node_dependency_sha256
)"
[ "$LEGACY_CONFIG_BEFORE" != "$LEGACY_CONFIG_AFTER" ] || {
  echo "legacy Node dependency hash가 manager config 변경을 놓쳤습니다." >&2
  exit 1
}

# legacy Node wrapper는 복합 Tauri 프로젝트도 Node adapter로 강제한다.
printf '%s\n' '{"scripts":{"build":"vite build"}}' > "$FIXTURE/tauri-mixed/package.json"
printf '%s\n' '{"productName":"Mixed","version":"1.0.0"}' > "$FIXTURE/tauri-mixed/src-tauri/tauri.conf.json"
PATH="$FIXTURE/bin:$PATH" UBS_TEST_LOG="$FIXTURE/mixed.log" UBS_SKIP_INSTALL=true \
  bash -c 'cd "$1" && bash "$2"' _ "$FIXTURE/tauri-mixed" "$ROOT/scripts/build-node.sh"
grep -Fqx 'run build' "$FIXTURE/mixed.log" || {
  echo "legacy Node wrapper가 Node adapter를 실행하지 않았습니다." >&2
  exit 1
}

# Tauri가 명시한 nested frontend는 별도 React 프로젝트로 중복 감지하지 않는다.
printf '%s\n' '{"productName":"Nested","version":"1.0.0","build":{"frontendDist":"../frontend/dist","beforeBuildCommand":"cd frontend && npm run build"}}' \
  > "$FIXTURE/tauri-nested/src-tauri/tauri.conf.json"
printf '%s\n' '{"scripts":{"build":"vite build"},"dependencies":{"react":"latest"}}' \
  > "$FIXTURE/tauri-nested/frontend/package.json"
NESTED_JSON="$("$ROOT/build.sh" detect --json "$FIXTURE/tauri-nested")"
printf '%s' "$NESTED_JSON" | python3 -c '
import json, sys
items = json.load(sys.stdin)
assert len(items) == 1 and items[0]["type"] == "tauri", items
'

# Gradle plan은 실제 최적화 flags를 구조화하고 Windows 경로를 보존한다.
GRADLE_PLAN="$(UBS_GRADLE_OPTIMIZE=true UBS_GRADLE_FLAGS='--scan' \
  "$ROOT/build.sh" plan --json "$FIXTURE/android")"
printf '%s' "$GRADLE_PLAN" | python3 -c '
import json, sys
options = json.load(sys.stdin)[0]["options"]
assert options["gradle_optimize"] is True
assert options["gradle_arguments"] == ["bundleRelease", "--build-cache", "--parallel", "--scan"]
'
python3 - "$ROOT/scripts/ubs.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ubs", sys.argv[1])
ubs = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = ubs
spec.loader.exec_module(ubs)
value = r'-PstoreFile=C:\Users\me\release.jks "-Pcache=C:\build cache"'
assert ubs.split_cli_arguments(value, windows=True) == [
    r'-PstoreFile=C:\Users\me\release.jks', r'-Pcache=C:\build cache'
]
PY

# Godot: export_presets.cfg의 실제 preset들이 detect/audit/plan/build 전체에서
# 올바르게 읽히는지 확인한다 — encrypt_pck·script_export_mode는 preset마다 다르다.
mkdir -p "$FIXTURE/godot"
printf '%s\n' '[application]' 'config/name="Demo"' 'config/version="0.1.0"' \
  > "$FIXTURE/godot/project.godot"
printf '%s\n' \
  '[preset.0]' '' 'name="iOS"' 'platform="iOS"' \
  'export_path="build/ios/demo.ipa"' 'encrypt_pck=false' 'encrypt_directory=false' \
  'script_export_mode=2' '' '[preset.0.options]' '' \
  'application/bundle_identifier="com.example.demo"' '' \
  '[preset.1]' '' 'name="Android"' 'platform="Android"' \
  'export_path="build/android/demo.apk"' 'encrypt_pck=true' 'encrypt_directory=false' \
  'script_export_mode=0' '' '[preset.1.options]' '' \
  'package/unique_name="com.example.demo"' \
  > "$FIXTURE/godot/export_presets.cfg"

GODOT_AUDIT="$("$ROOT/build.sh" audit --json "$FIXTURE/godot")"
printf '%s' "$GODOT_AUDIT" | python3 -c '
import json, sys
items = json.load(sys.stdin)
by_check = {item["check"]: item["status"] for item in items}
assert by_check["release-export"] == "enforced"
assert by_check["script-export-mode:iOS"] == "configured"
assert by_check["encrypt-pck:iOS"] == "not-configured"
assert by_check["script-export-mode:Android"] == "not-configured"
assert by_check["encrypt-pck:Android"] == "configured"
'

GODOT_PLAN_ANDROID="$(UBS_GODOT_PLATFORM=android "$ROOT/build.sh" plan --json "$FIXTURE/godot")"
printf '%s' "$GODOT_PLAN_ANDROID" | python3 -c '
import json, sys
item = json.load(sys.stdin)[0]
assert item["adapter"] == "scripts/ubs.py#godot"
presets = item["options"]["presets"]
assert len(presets) == 1
assert presets[0]["name"] == "Android"
assert presets[0]["export_path"] == "build/android/demo.apk"
'

if UBS_GODOT_PRESET=DoesNotExist "$ROOT/build.sh" plan --json "$FIXTURE/godot" >/dev/null 2>&1; then
  echo "존재하지 않는 UBS_GODOT_PRESET을 허용했습니다." >&2
  exit 1
fi

printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$UBS_TEST_LOG"' \
  > "$FIXTURE/bin/godot"
chmod +x "$FIXTURE/bin/godot"
PATH="$FIXTURE/bin:$PATH" UBS_TEST_LOG="$FIXTURE/godot.log" UBS_GODOT_PLATFORM=android \
  "$ROOT/build.sh" build --project "$FIXTURE/godot"
# $FIXTURE는 macOS에서 /var/folders/... (=> /private/var/folders/...로 심볼릭 링크)라
# 로그에 찍힌 canonicalize된 절대경로와 접두어가 다를 수 있다 — 의미 있는 부분(플래그·
# preset 이름·상대 출력 경로 꼬리)만 확인한다.
grep -Fq -- '--headless --path' "$FIXTURE/godot.log" || {
  echo "Godot adapter가 --headless --path를 전달하지 않았습니다." >&2
  exit 1
}
grep -Fq -- '--export-release Android' "$FIXTURE/godot.log" || {
  echo "Godot adapter가 Android preset으로 export-release를 실행하지 않았습니다." >&2
  exit 1
}
grep -Eq -- '/godot/build/android/demo\.apk( |$)' "$FIXTURE/godot.log" || {
  echo "Godot adapter가 preset의 export_path로 출력하지 않았습니다." >&2
  exit 1
}
[ -d "$FIXTURE/godot/build/android" ] || {
  echo "Godot adapter가 export_path의 상위 디렉터리를 만들지 않았습니다." >&2
  exit 1
}

echo "Python adapter·선택·캐시 테스트 통과"
