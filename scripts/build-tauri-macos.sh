#!/bin/bash

# =================================================================
# Tauri cross-platform production build script (plus macOS signing/package)
# Description: Tauri 2 production bundles on Windows/macOS/Linux, with
#              optional macOS App Store codesign and installer packaging.
# Features: Auto Version Bump, cross-platform bundle discovery, macOS .pkg
# Warning: 90886 재발 시 entitlements에 application-identifier를 수동 주입하지 말고 Apple Developer Forums / Tauri 이슈를 확인하세요.
# =================================================================

set -e

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/i18n.sh
source "$SCRIPT_DIR/lib/i18n.sh"

# ==========================================
# 빌드 스크립트 자체 업데이트 확인
# ==========================================

check_script_update() {
  [ "${UBS_ALLOW_SELF_UPDATE:-false}" = "true" ] || return 0
  echo -e "${YELLOW}$(ubs_msg SELF_UPDATE_DEPRECATED)${NC}" >&2
}

check_script_update "$@"

# ==========================================
# 프로젝트 확인
# ==========================================

CONF="src-tauri/tauri.conf.json"
if [ ! -f "$CONF" ]; then
  echo -e "${RED}❌ $(ubs_msg TAURI_CONF_NOT_FOUND)${NC}"
  echo -e "${YELLOW}   $(ubs_msg TAURI_CONF_RUN_FROM_ROOT)${NC}"
  exit 1
fi

HOST_OS="$(uname -s)"

command -v python3 >/dev/null 2>&1 || { echo -e "${RED}❌ $(ubs_msg PYTHON3_REQUIRED)${NC}"; exit 1; }

APP_NAME=$(python3 -c "import json;print(json.load(open('$CONF'))['productName'])")
CURRENT_VERSION=$(python3 -c "import json;print(json.load(open('$CONF'))['version'])")

echo -e "${CYAN}📦 $(ubs_msg APP_INFO "$APP_NAME" "$CURRENT_VERSION")${NC}"

# ==========================================
# 버전 자동 업데이트 (앱 버전)
# ==========================================

VERSION_NAME="$CURRENT_VERSION"

VERSION_CHANGED=false
BUILD_COMPLETED=false
VERSION_FILE_WAS_DIRTY=false
VERSION_BACKUP_FILE="$(mktemp "${TMPDIR:-/tmp}/ubs-tauri-version.XXXXXX")"
cp -p "$CONF" "$VERSION_BACKUP_FILE"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && {
  ! git ls-files --error-unmatch -- "$CONF" >/dev/null 2>&1 ||
  ! git diff --quiet -- "$CONF" ||
  ! git diff --cached --quiet -- "$CONF"
}; then
  VERSION_FILE_WAS_DIRTY=true
fi

set_tauri_version() {
  local version="$1"
  python3 - "$CONF" "$version" <<'PYEOF'
import re, sys
path, new_version = sys.argv[1], sys.argv[2]
content = open(path).read()
# 최상위(2-space 들여쓰기) "version" 키만 치환 — 들여쓰기 앵커 없이 첫 매치만 바꾸면
# bundle/plugins 등 중첩 설정의 "version" 필드를 잘못 건드릴 수 있다.
content, count = re.subn(
    r'^(  "version":\s*")[^"]+(")', rf'\g<1>{new_version}\g<2>', content, count=1, flags=re.MULTILINE
)
if count == 0:
    sys.exit(f'top-level "version" key not found: {path}')
open(path, "w").write(content)
PYEOF
}

# 빌드 번호(CFBundleVersion) — App Store Connect는 같은 빌드 번호의 재업로드를 거부한다.
# bundleVersion이 없으면 현재 앱 버전을 기준으로 다음 값을 만들고 명시적으로 추가한다.
CURRENT_BUNDLE_VERSION="$(python3 - "$CONF" <<'PYEOF'
import json, sys
try:
    config = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    print("")
    sys.exit(0)
bundle = config.get("bundle") or {}
macos = bundle.get("macOS") or {}
value = macos.get("bundleVersion")
print(value if isinstance(value, str) else "")
PYEOF
)"
BUNDLE_VERSION_CHANGED=false

set_tauri_bundle_version() {
  local version="$1"
  python3 - "$CONF" "$version" <<'PYEOF'
import json, os, sys, tempfile
path, new_version = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as source:
    config = json.load(source)
bundle = config.setdefault("bundle", {})
if not isinstance(bundle, dict):
    sys.exit(f'"bundle" must be an object: {path}')
macos = bundle.setdefault("macOS", {})
if not isinstance(macos, dict):
    sys.exit(f'"bundle.macOS" must be an object: {path}')
macos["bundleVersion"] = new_version
directory = os.path.dirname(os.path.abspath(path))
handle, temporary = tempfile.mkstemp(prefix=".tauri-conf-", suffix=".json", dir=directory)
try:
    with os.fdopen(handle, "w", encoding="utf-8") as output:
        json.dump(config, output, ensure_ascii=False, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PYEOF
}

# 마지막 숫자 컴포넌트만 +1 한다: 0.1.37 -> 0.1.38, 42 -> 43. 숫자로 끝나지 않으면 빈 문자열.
next_bundle_version() {
  python3 - "$1" <<'PYEOF'
import re, sys
match = re.match(r"^(.*?)(\d+)$", sys.argv[1])
print(f"{match.group(1)}{int(match.group(2)) + 1}" if match else "")
PYEOF
}

restore_version_if_incomplete() {
  if [ "$BUILD_COMPLETED" = true ]; then
    rm -f "$VERSION_BACKUP_FILE"
    return 0
  fi
  if [ "$VERSION_CHANGED" = true ] || [ "$BUNDLE_VERSION_CHANGED" = true ]; then
    cp -p "$VERSION_BACKUP_FILE" "$CONF"
  fi
  if [ "$VERSION_CHANGED" = true ]; then
    echo -e "${YELLOW}↩️  $(ubs_msg VERSION_RESTORED_INCOMPLETE "$CURRENT_VERSION")${NC}" >&2
  fi
  if [ "$BUNDLE_VERSION_CHANGED" = true ]; then
    echo -e "${YELLOW}↩️  $(ubs_msg TAURI_BUNDLE_VERSION_RESTORED "${CURRENT_BUNDLE_VERSION:-$CURRENT_VERSION}")${NC}" >&2
  fi
  rm -f "$VERSION_BACKUP_FILE"
}
trap restore_version_if_incomplete EXIT

# 빌드 번호 상향 정책: auto(기본) | none. 비대화형에서 앱 버전을 유지(none)하면
# 빌드 번호도 건드리지 않는다 — 에이전트의 일상 빌드가 커밋 대상 파일을 바꾸지 않도록.
BUNDLE_VERSION_POLICY="${UBS_BUNDLE_VERSION_BUMP:-auto}"

if [ "${UBS_NON_INTERACTIVE:-false}" = "true" ]; then
  case "${UBS_VERSION_BUMP:-none}" in
    build) VERSION_CHOICE=4 ;;
    patch) VERSION_CHOICE=1 ;;
    minor) VERSION_CHOICE=2 ;;
    major) VERSION_CHOICE=3 ;;
    none) VERSION_CHOICE=4; BUNDLE_VERSION_POLICY="${UBS_BUNDLE_VERSION_BUMP:-none}" ;;
    *) echo -e "${RED}$(ubs_msg VERSION_BUMP_UNSUPPORTED)${NC}" >&2; exit 2 ;;
  esac
  echo -e "${CYAN}$(ubs_msg VERSION_POLICY_NONINTERACTIVE "${UBS_VERSION_BUMP:-none}")${NC}"
else
  echo -e "${CYAN}$(ubs_msg MENU_VERSION_PROMPT)${NC}"
  NEXT_PATCH="$(echo "$VERSION_NAME" | awk -F. '{print $1"."$2"."$3+1}')"
  NEXT_MINOR="$(echo "$VERSION_NAME" | awk -F. '{print $1"."$2+1".0"}')"
  NEXT_MAJOR="$(echo "$VERSION_NAME" | awk -F. '{print $1+1".0.0"}')"
  echo -e "  ${YELLOW}$(ubs_msg TAURI_MENU_OPT_PATCH_BUMP)${NC}  → ${NEXT_PATCH}"
  echo -e "  ${YELLOW}$(ubs_msg TAURI_MENU_OPT_MINOR_BUMP)${NC}  → ${NEXT_MINOR}"
  echo -e "  ${YELLOW}$(ubs_msg TAURI_MENU_OPT_MAJOR_BUMP)${NC}  → ${NEXT_MAJOR}"
  echo -e "  ${YELLOW}$(ubs_msg MENU_OPT_KEEP_VERSION)${NC}"
  echo -e "  ${YELLOW}$(ubs_msg MENU_OPT_CANCEL)${NC}"
  if [ "$BUNDLE_VERSION_POLICY" = "auto" ]; then
    EFFECTIVE_BUNDLE_VERSION="${CURRENT_BUNDLE_VERSION:-$CURRENT_VERSION}"
    PLANNED_BUNDLE_VERSION="$(next_bundle_version "$EFFECTIVE_BUNDLE_VERSION")"
    if [ -n "$PLANNED_BUNDLE_VERSION" ]; then
      echo -e "${CYAN}$(ubs_msg TAURI_BUNDLE_VERSION_PLAN "$EFFECTIVE_BUNDLE_VERSION" "$PLANNED_BUNDLE_VERSION")${NC}"
    fi
  fi
  read -p "$(ubs_msg CHOICE_PROMPT_1_5)" VERSION_CHOICE
fi

case $VERSION_CHOICE in
  1) NEW_VERSION=$(echo $VERSION_NAME | awk -F. '{print $1"."$2"."$3+1}') ;;
  2) NEW_VERSION=$(echo $VERSION_NAME | awk -F. '{print $1"."$2+1".0"}') ;;
  3) NEW_VERSION=$(echo $VERSION_NAME | awk -F. '{print $1+1".0.0"}') ;;
  4) NEW_VERSION="$CURRENT_VERSION"; echo -e "${CYAN}$(ubs_msg VERSION_KEPT "$NEW_VERSION")${NC}" ;;
  5) echo -e "${YELLOW}$(ubs_msg BUILD_CANCELLED)${NC}"; exit 0 ;;
  *) echo -e "${RED}$(ubs_msg VERSION_INVALID_CHOICE)${NC}"; NEW_VERSION="$CURRENT_VERSION" ;;
esac

if [ "$NEW_VERSION" != "$CURRENT_VERSION" ]; then
  set_tauri_version "$NEW_VERSION"
  VERSION_CHANGED=true
  echo -e "${GREEN}✅ $(ubs_msg VERSION_UPDATED "$CURRENT_VERSION" "$NEW_VERSION")${NC}"
fi

# 빌드 번호는 앱 버전 선택과 무관하게 올린다 — App Store Connect가 요구하는 건
# CFBundleShortVersionString이 아니라 CFBundleVersion의 단조 증가다.
if [ "$BUNDLE_VERSION_POLICY" = "auto" ]; then
  EFFECTIVE_BUNDLE_VERSION="${CURRENT_BUNDLE_VERSION:-$CURRENT_VERSION}"
  NEW_BUNDLE_VERSION="$(next_bundle_version "$EFFECTIVE_BUNDLE_VERSION")"
  if [ -n "$NEW_BUNDLE_VERSION" ]; then
    set_tauri_bundle_version "$NEW_BUNDLE_VERSION"
    BUNDLE_VERSION_CHANGED=true
    echo -e "${GREEN}✅ $(ubs_msg TAURI_BUNDLE_VERSION_UPDATED "$EFFECTIVE_BUNDLE_VERSION" "$NEW_BUNDLE_VERSION")${NC}"
  else
    echo -e "${YELLOW}$(ubs_msg TAURI_BUNDLE_VERSION_NOT_NUMERIC "$EFFECTIVE_BUNDLE_VERSION")${NC}" >&2
  fi
fi

# ==========================================
# 서명 설정 확인 (.env.macos)
# ==========================================

ENV_FILE=".env.macos"
dotenv_value() {
  python3 - "$ENV_FILE" "$1" <<'PYEOF'
import sys
path, wanted = sys.argv[1], sys.argv[2]
try:
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() != wanted:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        print(value, end="")
        break
except FileNotFoundError:
    pass
PYEOF
}

if [ -f "$ENV_FILE" ]; then
  TAURI_SIGN_IDENTITY="${TAURI_SIGN_IDENTITY:-$(dotenv_value TAURI_SIGN_IDENTITY)}"
  TAURI_INSTALLER_IDENTITY="${TAURI_INSTALLER_IDENTITY:-$(dotenv_value TAURI_INSTALLER_IDENTITY)}"
  TAURI_PROVISION_PROFILE="${TAURI_PROVISION_PROFILE:-$(dotenv_value TAURI_PROVISION_PROFILE)}"
  TAURI_ENTITLEMENTS="${TAURI_ENTITLEMENTS:-$(dotenv_value TAURI_ENTITLEMENTS)}"
  TAURI_OBFUSCATE_JS="${TAURI_OBFUSCATE_JS:-$(dotenv_value TAURI_OBFUSCATE_JS)}"
fi

SIGNING_DIR="signing"
PROVISION_PROFILE="${TAURI_PROVISION_PROFILE:-$(find "$SIGNING_DIR" -maxdepth 1 -iname '*.provisionprofile' 2>/dev/null | head -1)}"
ENTITLEMENTS="${TAURI_ENTITLEMENTS:-$(find "$SIGNING_DIR" -maxdepth 1 -iname '*.entitlements' 2>/dev/null | head -1)}"
PACKAGE_MODE="${UBS_TAURI_PACKAGE_MODE:-auto}"
SIGN_PACKAGE=false
SIGNING_READY=true
[ -n "${TAURI_SIGN_IDENTITY:-}" ] || SIGNING_READY=false
[ -n "${TAURI_INSTALLER_IDENTITY:-}" ] || SIGNING_READY=false
[ -n "$PROVISION_PROFILE" ] && [ -f "$PROVISION_PROFILE" ] || SIGNING_READY=false
[ -n "$ENTITLEMENTS" ] && [ -f "$ENTITLEMENTS" ] || SIGNING_READY=false

case "$PACKAGE_MODE" in
  auto)
    if [ "$HOST_OS" != "Darwin" ]; then
      echo -e "${CYAN}ℹ️  $(ubs_msg PKG_MODE_AUTO_NON_MACOS "$HOST_OS")${NC}"
    elif [ "$SIGNING_READY" = true ]; then SIGN_PACKAGE=true
    else echo -e "${YELLOW}ℹ️  $(ubs_msg PKG_MODE_AUTO_SIGNING_INCOMPLETE)${NC}"
    fi
    ;;
  signed)
    if [ "$HOST_OS" != "Darwin" ]; then
      echo -e "${RED}❌ $(ubs_msg PKG_MODE_SIGNED_MACOS_ONLY)${NC}" >&2
      exit 1
    fi
    if [ "$SIGNING_READY" != true ]; then
      echo -e "${RED}❌ $(ubs_msg PKG_MODE_SIGNED_REQUIREMENTS)${NC}" >&2
      exit 1
    fi
    SIGN_PACKAGE=true
    ;;
  unsigned) SIGN_PACKAGE=false ;;
  *) echo -e "${RED}❌ $(ubs_msg PKG_MODE_INVALID)${NC}" >&2; exit 2 ;;
esac

if [ "$SIGN_PACKAGE" = true ]; then
  echo -e "${CYAN}🔑 $(ubs_msg SIGN_IDENTITY_LABEL "$TAURI_SIGN_IDENTITY")${NC}"
  echo -e "${CYAN}📄 $(ubs_msg PROVISION_PROFILE_LABEL "$PROVISION_PROFILE")${NC}"
fi

# ==========================================
# 환경변수 주입 확인 (.env → import.meta.env)
# ==========================================

# Vite는 프로젝트 루트의 .env / .env.production 을 별도 플래그 없이 자동으로 읽어
# `VITE_` 접두사가 붙은 값을 import.meta.env.VITE_* 로 프런트엔드 빌드에 주입한다.
# (Flutter의 --dart-define-from-file 과 동일한 역할, Vite는 기본 내장 기능)
if [ -f ".env" ] || [ -f ".env.production" ]; then
  echo -e "${CYAN}🔑 $(ubs_msg FRONTEND_ENV_DETECTED)${NC}"
fi

# ==========================================
# JS 난독화 옵션 (TAURI_OBFUSCATE_JS=true)
# ==========================================

# Tauri 프런트엔드(JS/TS)는 Dart AOT처럼 네이티브로 컴파일되지 않고 텍스트로 번들에 포함된다.
# Vite가 기본으로 minify는 하지만(변수명 축약) 진짜 난독화(제어 흐름 변형, 문자열 암호화)는 아니다.
# 이 옵션을 켜면 javascript-obfuscator로 dist/ 산출물을 한 번 더 난독화한 뒤,
# --config로 beforeBuildCommand를 비워 tauri build가 그 결과를 덮어쓰지 않게 한다.
OBFUSCATE_JS="${TAURI_OBFUSCATE_JS:-false}"

# ==========================================
# macOS 유니버설 바이너리 (Apple Silicon + Intel)
# ==========================================

# tauri build --target universal-apple-darwin는 aarch64/x86_64 두 슬라이스를
# lipo로 합친 .app 하나를 만든다 — 배포 산출물은 여전히 1개.
TAURI_TARGET_ARGS=()
if [ "$HOST_OS" = "Darwin" ] && [ "${TAURI_UNIVERSAL_MACOS:-true}" = "true" ]; then
  if command -v rustup >/dev/null 2>&1; then
    for triple in aarch64-apple-darwin x86_64-apple-darwin; do
      rustup target list --installed 2>/dev/null | grep -qx "$triple" || rustup target add "$triple"
    done
    echo -e "${CYAN}🌐 $(ubs_msg UNIVERSAL_BUILD_ENABLED)${NC}"
    TAURI_TARGET_ARGS=(--target universal-apple-darwin)
  else
    echo -e "${YELLOW}⚠️  $(ubs_msg UNIVERSAL_BUILD_NO_RUSTUP)${NC}"
  fi
fi

# ==========================================
# 빌드 시작
# ==========================================

BUILD_START_TS=$(date +%s)

# shellcheck source=lib/node-package-manager.sh
HAS_NODE_PROJECT=false
if [ -f package.json ]; then
  HAS_NODE_PROJECT=true
  source "$SCRIPT_DIR/lib/node-package-manager.sh"
  detect_node_package_manager
  if [ "${UBS_SKIP_INSTALL:-false}" != "true" ]; then
    echo -e "${BLUE}📥 $(ubs_msg NODE_INSTALL_RUNNING "$NODE_PM")${NC}"
    install_node_dependencies
  else
    echo -e "${CYAN}ℹ️  $(ubs_msg SKIP_INSTALL_ENABLED)${NC}"
  fi
else
  echo -e "${CYAN}ℹ️  $(ubs_msg TAURI_STATIC_FRONTEND_CARGO)${NC}"
fi

run_tauri_build() {
  if [ "$HAS_NODE_PROJECT" = true ]; then
    run_node_script tauri build -- "$@"
    return
  fi
  command -v cargo >/dev/null 2>&1 || {
    echo -e "${RED}❌ $(ubs_msg CARGO_TAURI_REQUIRED)${NC}" >&2
    return 1
  }
  cargo tauri build "$@"
}

if [ "$OBFUSCATE_JS" = "true" ]; then
  if [ "$HAS_NODE_PROJECT" != true ]; then
    echo -e "${RED}❌ $(ubs_msg TAURI_STATIC_OBFUSCATION_UNSUPPORTED)${NC}" >&2
    exit 1
  fi
  echo -e "${BLUE}🚀 $(ubs_msg STEP_FRONTEND_BUILD_1OF4)${NC}"
  run_node_script build

  echo -e "${YELLOW}🔒 $(ubs_msg STEP_JS_OBFUSCATE_2OF4)${NC}"
  OBFUSCATOR="$NODE_WORKSPACE_ROOT/node_modules/.bin/javascript-obfuscator"
  OBFUSCATOR_CMD=("$OBFUSCATOR")
  if [ "${OS:-}" = "Windows_NT" ] && [ -f "$OBFUSCATOR.cmd" ]; then
    OBFUSCATOR_CMD=(cmd.exe /c "$OBFUSCATOR.cmd")
  fi
  [ -x "$OBFUSCATOR" ] || [ ${#OBFUSCATOR_CMD[@]} -gt 1 ] || {
    echo -e "${RED}❌ $(ubs_msg OBFUSCATOR_NOT_FOUND)${NC}" >&2
    echo -e "${YELLOW}   $(ubs_msg OBFUSCATOR_PIN_HINT)${NC}" >&2
    exit 1
  }
  if ! "${OBFUSCATOR_CMD[@]}" dist --output dist \
    --compact true --control-flow-flattening true --string-array true \
    --string-array-encoding base64 --self-defending true; then
    echo -e "${RED}❌ $(ubs_msg OBFUSCATOR_RUN_FAILED)${NC}"
    exit 1
  fi

  echo -e "${BLUE}🚀 $(ubs_msg STEP_TAURI_BUILD_3OF4)${NC}"
  run_tauri_build --config '{"build":{"beforeBuildCommand":""}}' "${TAURI_TARGET_ARGS[@]}" "$@"
else
  echo -e "${BLUE}🚀 $(ubs_msg STEP_TAURI_BUILD_1OF3)${NC}"
  run_tauri_build "${TAURI_TARGET_ARGS[@]}" "$@"
  echo -e "${CYAN}ℹ️  $(ubs_msg JS_OBFUSCATE_DISABLED_HINT)${NC}"
fi

if [ "$HOST_OS" = "Darwin" ]; then
  BUNDLE_TARGET_DIR="release"
  [ ${#TAURI_TARGET_ARGS[@]} -eq 0 ] || BUNDLE_TARGET_DIR="${TAURI_TARGET_ARGS[1]}/release"
  BUNDLE_APP="src-tauri/target/${BUNDLE_TARGET_DIR}/bundle/macos/${APP_NAME}.app"
  [ -d "$BUNDLE_APP" ] || { echo -e "${RED}❌ $(ubs_msg BUNDLE_APP_NOT_FOUND "$BUNDLE_APP")${NC}"; exit 1; }
  ARTIFACT_OUT="$BUNDLE_APP"
else
  ARTIFACT_OUT="$(find src-tauri/target/release/bundle -mindepth 2 -maxdepth 3 \( -type f -o -type d \) 2>/dev/null | head -1)"
  [ -n "$ARTIFACT_OUT" ] || { echo -e "${RED}❌ $(ubs_msg BUNDLE_ARTIFACT_NOT_FOUND)${NC}"; exit 1; }
fi
RESULT_DIR="$(dirname "$ARTIFACT_OUT")"
ARTIFACT_LABEL="$(basename "$ARTIFACT_OUT")"

if [ "$SIGN_PACKAGE" = true ]; then
  echo -e "${YELLOW}🛡️ $(ubs_msg CODESIGNING_START)${NC}"
  echo -e "${CYAN}🧹 $(ubs_msg XATTR_CLEAR)${NC}"
  xattr -cr "$PROVISION_PROFILE" "$BUNDLE_APP"
  cp "$PROVISION_PROFILE" "$BUNDLE_APP/Contents/embedded.provisionprofile"
  codesign --deep --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$TAURI_SIGN_IDENTITY" \
    "$BUNDLE_APP"
  codesign --verify --deep --strict --verbose=2 "$BUNDLE_APP"

  echo -e "${YELLOW}📦 $(ubs_msg BUILDING_SIGNED_PKG)${NC}"
  mkdir -p "$SIGNING_DIR/build"
  PKG_OUT="$SIGNING_DIR/build/${APP_NAME}.pkg"
  productbuild --component "$BUNDLE_APP" /Applications \
    --sign "$TAURI_INSTALLER_IDENTITY" \
    "$PKG_OUT"
  ARTIFACT_OUT="$PKG_OUT"
  RESULT_DIR="$SIGNING_DIR/build"
  ARTIFACT_LABEL="$APP_NAME.pkg"
fi
BUILD_COMPLETED=true

# ==========================================
# 버전 변경 커밋 (안 하면 uncommitted diff로 계속 쌓임 — #26)
# ==========================================

if [ "$VERSION_CHANGED" = true ] || [ "$BUNDLE_VERSION_CHANGED" = true ]; then
  COMMIT_VERSION="$NEW_VERSION"
  if [ "$BUNDLE_VERSION_CHANGED" = true ]; then
    COMMIT_VERSION="${COMMIT_VERSION} (build ${NEW_BUNDLE_VERSION})"
  fi
  if [ "$VERSION_FILE_WAS_DIRTY" = true ]; then
    echo -e "${YELLOW}⚠️  $(ubs_msg VERSION_COMMIT_SKIPPED_DIRTY "$CONF")${NC}" >&2
  elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add -- "$CONF" 2>/dev/null
    if git commit -m "chore: ${APP_NAME} 버전 ${COMMIT_VERSION}" -- "$CONF" >/dev/null 2>&1; then
      echo -e "${GREEN}✅ $(ubs_msg VERSION_COMMIT_SUCCESS_APP "$APP_NAME" "$COMMIT_VERSION")${NC}"
    else
      echo -e "${YELLOW}⚠️  $(ubs_msg VERSION_COMMIT_FAILED "$NEW_VERSION")${NC}" >&2
    fi
  else
    echo -e "${YELLOW}⚠️  $(ubs_msg VERSION_COMMIT_NOT_GIT_REPO "$NEW_VERSION")${NC}" >&2
  fi
fi

# ==========================================
# 빌드 완료 알림
# ==========================================

BUILD_END_TS=$(date +%s)
BUILD_ELAPSED=$((BUILD_END_TS - BUILD_START_TS))
BUILD_ELAPSED_MIN=$((BUILD_ELAPSED / 60))
BUILD_ELAPSED_SEC=$((BUILD_ELAPSED % 60))
BUILD_ELAPSED_FMT="${BUILD_ELAPSED_MIN}m ${BUILD_ELAPSED_SEC}s"

if [[ "$OSTYPE" == "darwin"* ]] && [ "${UBS_NO_NOTIFY:-false}" != "true" ]; then
  # 빌드는 이미 성공했으므로 알림 명령 실패로 스크립트 전체가 죽지 않도록 best-effort 처리.
  afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true
  say "$(ubs_msg NOTIFY_TTS_BUILD_COMPLETE)" 2>/dev/null || true
  osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 3 of argv) subtitle (item 2 of argv)' \
    -e 'end run' \
    "$(ubs_msg NOTIFY_BUILD_DONE "$NEW_VERSION" "$BUILD_ELAPSED_FMT")" \
    "$(ubs_msg NOTIFY_SUBTITLE_ARTIFACT_READY "$ARTIFACT_LABEL")" \
    "✅ $(ubs_msg NOTIFY_TITLE_BUILD_FINISHED)" 2>/dev/null || true
fi

echo -e "------------------------------------------------------------"
echo -e "${GREEN}✅ $(ubs_msg BUILD_SUCCESS_BANNER)${NC}"
echo -e "🏷️  $(ubs_msg SUMMARY_VERSION "$NEW_VERSION")"
echo -e "📍 $(ubs_msg SUMMARY_ARTIFACT "$ARTIFACT_OUT")"
echo -e "⏱️  $(ubs_msg SUMMARY_BUILD_TIME "$BUILD_ELAPSED_FMT")"
echo -e "------------------------------------------------------------"
if [ "$SIGN_PACKAGE" = true ]; then
  echo -e "${CYAN}ℹ️  $(ubs_msg TRANSPORTER_UPLOAD_HINT "$ARTIFACT_OUT")${NC}"
fi
