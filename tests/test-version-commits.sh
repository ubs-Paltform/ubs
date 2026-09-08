#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/tauri/src-tauri" "$FIXTURE/flutter"

git_init() {
  git -C "$1" init -q
  git -C "$1" config user.name "UBS Test"
  git -C "$1" config user.email "ubs-test@example.invalid"
  git -C "$1" add .
  git -C "$1" commit -qm initial
}

printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "--version" ]; then echo 10.0.0; exit 0; fi' \
  'mkdir -p src-tauri/target/release/bundle/macos/Demo.app/Contents' \
  'mkdir -p src-tauri/target/release/bundle/deb' \
  ': > src-tauri/target/release/bundle/deb/demo.deb' \
  > "$FIXTURE/bin/npm"
chmod +x "$FIXTURE/bin/npm"

printf '%s\n' \
  '{' \
  '  "productName": "Demo",' \
  '  "version": "1.0.0",' \
  '  "bundle": {"macOS": {"bundleVersion": "1"}}' \
  '}' > "$FIXTURE/tauri/src-tauri/tauri.conf.json"
printf '%s\n' '{"scripts":{"tauri":"tauri"}}' > "$FIXTURE/tauri/package.json"
git_init "$FIXTURE/tauri"

PATH="$FIXTURE/bin:$PATH" UBS_NON_INTERACTIVE=true UBS_VERSION_BUMP=none \
  UBS_BUNDLE_VERSION_BUMP=auto UBS_TAURI_PACKAGE_MODE=auto UBS_SKIP_INSTALL=true \
  UBS_NO_NOTIFY=true TAURI_UNIVERSAL_MACOS=false \
  bash -c 'cd "$1" && bash "$2"' _ "$FIXTURE/tauri" "$ROOT/scripts/build-tauri-macos.sh" \
  >/dev/null
[ "$(git -C "$FIXTURE/tauri" rev-list --count HEAD)" -eq 2 ] || {
  echo "Tauri bundle-only 버전 변경이 커밋되지 않았습니다." >&2
  exit 1
}
python3 - "$FIXTURE/tauri/src-tauri/tauri.conf.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["bundle"]["macOS"]["bundleVersion"] == "2"
PY

python3 - "$FIXTURE/tauri/src-tauri/tauri.conf.json" <<'PY'
import json, sys
path = sys.argv[1]
config = json.load(open(path, encoding="utf-8"))
config["userNote"] = "preserve"
with open(path, "w", encoding="utf-8") as output:
    json.dump(config, output, indent=2)
    output.write("\n")
PY
TAURI_DIRTY_OUTPUT="$(PATH="$FIXTURE/bin:$PATH" UBS_LANG=ko UBS_NON_INTERACTIVE=true \
  UBS_VERSION_BUMP=none UBS_BUNDLE_VERSION_BUMP=auto UBS_TAURI_PACKAGE_MODE=auto \
  UBS_SKIP_INSTALL=true UBS_NO_NOTIFY=true TAURI_UNIVERSAL_MACOS=false \
  bash -c 'cd "$1" && bash "$2"' _ "$FIXTURE/tauri" "$ROOT/scripts/build-tauri-macos.sh" 2>&1)"
[ "$(git -C "$FIXTURE/tauri" rev-list --count HEAD)" -eq 2 ] || {
  echo "Tauri가 기존 dirty 설정을 자동 커밋했습니다." >&2
  exit 1
}
printf '%s\n' "$TAURI_DIRTY_OUTPUT" | grep -Fq '기존 변경을 보호' || {
  echo "Tauri dirty 커밋 건너뜀 경고가 없습니다." >&2
  exit 1
}
python3 - "$FIXTURE/tauri/src-tauri/tauri.conf.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8"))
assert config["userNote"] == "preserve"
assert config["bundle"]["macOS"]["bundleVersion"] == "3"
PY

printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "--version" ]; then echo 3.35.0; exit 0; fi' \
  'if [ "${1:-} ${2:-}" = "build web" ] && [ ! -e build/web/index.html ]; then mkdir -p build/web; : > build/web/index.html; fi' \
  > "$FIXTURE/bin/flutter"
chmod +x "$FIXTURE/bin/flutter"
printf '%s\n' 'name: fixture' 'version: 1.0.0+1' 'dependencies:' '  flutter:' '    sdk: flutter' \
  > "$FIXTURE/flutter/pubspec.yaml"
git_init "$FIXTURE/flutter"
printf '%s\n' '# user change' >> "$FIXTURE/flutter/pubspec.yaml"
ARTIFACT_SCOPE_FILE="$FIXTURE/flutter-artifact-scope"
: > "$ARTIFACT_SCOPE_FILE"
FLUTTER_DIRTY_OUTPUT="$(PATH="$FIXTURE/bin:$PATH" UBS_LANG=ko UBS_NON_INTERACTIVE=true \
  UBS_VERSION_BUMP=patch UBS_FLUTTER_OUTPUTS=web UBS_SKIP_CLEAN=true UBS_NO_NOTIFY=true \
  UBS_INTERNAL_ARTIFACT_SCOPE_FILE="$ARTIFACT_SCOPE_FILE" \
  bash -c 'cd "$1" && bash "$2"' _ "$FIXTURE/flutter" "$ROOT/scripts/build-flutter.sh" 2>&1)"
[ "$(git -C "$FIXTURE/flutter" rev-list --count HEAD)" -eq 1 ] || {
  echo "Flutter가 기존 dirty pubspec을 자동 커밋했습니다." >&2
  exit 1
}
grep -Fqx '# user change' "$FIXTURE/flutter/pubspec.yaml"
grep -Fqx 'version: 1.0.1+2' "$FIXTURE/flutter/pubspec.yaml"
grep -Fqx 'web' "$ARTIFACT_SCOPE_FILE" || {
  echo "Flutter 선택 출력이 아티팩트 범위 파일에 기록되지 않았습니다." >&2
  exit 1
}
printf '%s\n' "$FLUTTER_DIRTY_OUTPUT" | grep -Fq '기존 변경을 보호' || {
  echo "Flutter dirty 커밋 건너뜀 경고가 없습니다." >&2
  exit 1
}

# 다시 빌드해도 파일을 갱신하지 않는 UP-TO-DATE 산출물은 포함하고,
# 이번 실행에서 선택하지 않은 예전 iOS 산출물은 제외한다.
mkdir -p "$FIXTURE/flutter/build/ios/ipa"
: > "$FIXTURE/flutter/build/ios/ipa/stale.ipa"
touch -t 202001010000 "$FIXTURE/flutter/build/web/index.html" \
  "$FIXTURE/flutter/build/web" "$FIXTURE/flutter/build/ios/ipa/stale.ipa"
REPORT_PATH="$FIXTURE/flutter-report.json"
PATH="$FIXTURE/bin:$PATH" UBS_NO_OPEN=true \
  "$ROOT/build.sh" build --non-interactive --version-bump none --flutter-outputs web \
  --report-json "$REPORT_PATH" --project "$FIXTURE/flutter" >/dev/null
python3 - "$REPORT_PATH" "$FIXTURE/flutter/build/web" <<'PY'
import json, sys
from pathlib import Path
artifacts = json.load(open(sys.argv[1], encoding="utf-8"))["results"][0]["artifacts"]
assert artifacts == [str(Path(sys.argv[2]).resolve())], artifacts
PY

echo "버전 커밋 보호 테스트 통과"
