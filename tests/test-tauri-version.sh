#!/usr/bin/env bash

# build-tauri-macos.sh의 버전 헬퍼 회귀 테스트.
# App Store Connect가 거부하는 건 CFBundleShortVersionString이 아니라 CFBundleVersion의
# 중복이므로, bundleVersion이 실제로 단조 증가하는지와 두 키가 서로를 덮지 않는지를 본다.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

# 전체 빌드 파이프라인을 돌리지 않고 헬퍼 함수 정의부만 잘라내 검증한다.
sed -n \
  -e '/^set_tauri_version() {/,/^}/p' \
  -e '/^set_tauri_bundle_version() {/,/^}/p' \
  -e '/^next_bundle_version() {/,/^}/p' \
  "$ROOT/scripts/build-tauri-macos.sh" > "$FIXTURE/helpers.sh"

for fn in set_tauri_version set_tauri_bundle_version next_bundle_version; do
  grep -q "^${fn}() {" "$FIXTURE/helpers.sh" || {
    echo "헬퍼 추출 실패: $fn" >&2
    exit 1
  }
done

CONF="$FIXTURE/tauri.conf.json"
# shellcheck source=/dev/null
source "$FIXTURE/helpers.sh"

cat > "$CONF" <<'JSON'
{
  "productName": "fixture",
  "version": "1.0.0",
  "bundle": {
    "macOS": {
      "bundleVersion": "0.1.37",
      "minimumSystemVersion": "13.0"
    }
  },
  "plugins": {
    "updater": { "version": "9.9.9" }
  }
}
JSON

conf_value() {
  python3 - "$CONF" "$1" <<'PYEOF'
import json, sys
config = json.load(open(sys.argv[1]))
path = sys.argv[2].split(".")
for key in path:
    config = config[key]
print(config)
PYEOF
}

# 1) 마지막 숫자 컴포넌트만 +1
[ "$(next_bundle_version 0.1.37)" = "0.1.38" ] || { echo "next_bundle_version(0.1.37) 실패" >&2; exit 1; }
[ "$(next_bundle_version 42)" = "43" ] || { echo "next_bundle_version(42) 실패" >&2; exit 1; }
[ "$(next_bundle_version 1.0.9)" = "1.0.10" ] || { echo "next_bundle_version(1.0.9) 실패" >&2; exit 1; }

# 2) 숫자로 끝나지 않으면 빈 문자열(호출부가 자동 상향을 건너뛴다)
[ -z "$(next_bundle_version 1.0-beta)" ] || { echo "숫자 아닌 빌드 번호를 걸러내지 못했습니다." >&2; exit 1; }

# 3) bundleVersion만 바뀌고 최상위 version과 중첩 version은 그대로
set_tauri_bundle_version "$(next_bundle_version 0.1.37)"
[ "$(conf_value bundle.macOS.bundleVersion)" = "0.1.38" ] || { echo "bundleVersion 상향 실패" >&2; exit 1; }
[ "$(conf_value version)" = "1.0.0" ] || { echo "bundleVersion 상향이 최상위 version을 건드렸습니다." >&2; exit 1; }
[ "$(conf_value plugins.updater.version)" = "9.9.9" ] || { echo "중첩 version이 훼손됐습니다." >&2; exit 1; }

# 4) 최상위 version만 바뀌고 bundleVersion/중첩 version은 그대로
set_tauri_version "1.1.0"
[ "$(conf_value version)" = "1.1.0" ] || { echo "version 상향 실패" >&2; exit 1; }
[ "$(conf_value bundle.macOS.bundleVersion)" = "0.1.38" ] || { echo "version 상향이 bundleVersion을 건드렸습니다." >&2; exit 1; }
[ "$(conf_value plugins.updater.version)" = "9.9.9" ] || { echo "version 상향이 중첩 version을 건드렸습니다." >&2; exit 1; }

echo "test-tauri-version: ok"
