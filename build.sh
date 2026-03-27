#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/V2rayNG"
APP_LIBS_DIR="$APP_DIR/app/libs"
ROOT_LIBS_DIR="$ROOT_DIR/libs"

log() {
  printf '[build.sh] %s\n' "$*"
}

die() {
  printf '[build.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./build.sh [playstore-signed|signed|fdroid-signed|fdroid|playstore]

Modes:
  playstore-signed  Build signed playstore release APKs (default)
  signed            Alias of playstore-signed
  fdroid-signed     Build signed fdroid release APKs (installable side-by-side)
  fdroid            Build unsigned fdroid release APKs
  playstore         Build unsigned playstore release APKs

Optional env vars:
  JAVA_HOME
  ANDROID_HOME
  ANDROID_SDK_ROOT
  NDK_HOME
  ABI_FILTERS               e.g. arm64-v8a;x86_64
  LIBV2RAY_TAG              override AndroidLibXrayLite tag
  LIBV2RAY_AAR_URL          override AAR download URL

For playstore-signed mode:
  Interactive mode:
    Prompts for missing KEYSTORE_FILE / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD
  Non-interactive mode (CI):
    Set KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD
    Optional: KEYSTORE_FILE (default: .keys/release.jks)
USAGE
}

MODE="${1:-playstore-signed}"
case "$MODE" in
  fdroid|playstore|playstore-signed|signed|fdroid-signed)
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage
    die "unknown mode: $MODE"
    ;;
esac

setup_env() {
  if [[ -z "${JAVA_HOME:-}" ]]; then
    if [[ -x "/opt/android-studio/jbr/bin/java" ]]; then
      export JAVA_HOME="/opt/android-studio/jbr"
    else
      die "JAVA_HOME is not set, and /opt/android-studio/jbr is unavailable"
    fi
  fi

  if [[ -z "${ANDROID_HOME:-}" ]]; then
    if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
      export ANDROID_HOME="$ANDROID_SDK_ROOT"
    elif [[ -d "/home/miaospring/Android/Sdk" ]]; then
      export ANDROID_HOME="/home/miaospring/Android/Sdk"
    else
      die "ANDROID_HOME/ANDROID_SDK_ROOT is not set"
    fi
  fi

  if [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
  fi

  if [[ -z "${NDK_HOME:-}" ]]; then
    local ndk_dir
    ndk_dir="$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n 1 || true)"
    [[ -n "$ndk_dir" ]] || die "NDK_HOME is not set and no NDK found under $ANDROID_HOME/ndk"
    export NDK_HOME="$ndk_dir"
  fi

  export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

  log "JAVA_HOME=$JAVA_HOME"
  log "ANDROID_HOME=$ANDROID_HOME"
  log "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
  log "NDK_HOME=$NDK_HOME"
}

init_submodules() {
  log "Initializing submodules"
  git -C "$ROOT_DIR" submodule update --init --recursive
}

prepare_libhevtun() {
  log "Building libhevtun via compile-hevtun.sh"
  (cd "$ROOT_DIR" && bash compile-hevtun.sh)

  log "Syncing libhevtun .so files into app/libs"
  mkdir -p "$APP_LIBS_DIR"
  cp -r "$ROOT_LIBS_DIR"/* "$APP_LIBS_DIR"/
}

prepare_libv2ray() {
  mkdir -p "$APP_LIBS_DIR"

  local tag url
  if [[ -n "${LIBV2RAY_AAR_URL:-}" ]]; then
    url="$LIBV2RAY_AAR_URL"
  else
    if [[ -n "${LIBV2RAY_TAG:-}" ]]; then
      tag="$LIBV2RAY_TAG"
    else
      tag="$(git -C "$ROOT_DIR/AndroidLibXrayLite" describe --tags --abbrev=0)"
    fi
    url="https://github.com/2dust/AndroidLibXrayLite/releases/download/${tag}/libv2ray.aar"
  fi

  log "Downloading libv2ray.aar"
  curl -fL --retry 3 --retry-all-errors -o "$APP_LIBS_DIR/libv2ray.aar" "$url"
}

write_local_properties() {
  log "Writing local.properties"
  printf 'sdk.dir=%s\n' "$ANDROID_HOME" > "$APP_DIR/local.properties"
}

prompt_env() {
  local var_name prompt_text secret default_value value
  var_name="$1"
  prompt_text="$2"
  secret="${3:-false}"
  default_value="${4:-}"
  value="${!var_name:-}"

  if [[ -z "$value" ]]; then
    if [[ -t 0 ]]; then
      if [[ "$secret" == "true" ]]; then
        read -r -s -p "$prompt_text: " value
        echo
      else
        if [[ -n "$default_value" ]]; then
          read -r -p "$prompt_text [$default_value]: " value
          value="${value:-$default_value}"
        else
          read -r -p "$prompt_text: " value
        fi
      fi
    else
      if [[ -n "$default_value" ]]; then
        value="$default_value"
      else
        die "$var_name is required in non-interactive mode"
      fi
    fi
  fi

  [[ -n "$value" ]] || die "$var_name is required"
  printf -v "$var_name" '%s' "$value"
  export "$var_name"
}

run_gradle_build() {
  local -a gradle_args
  gradle_args=(--no-daemon)

  if [[ -n "${ABI_FILTERS:-}" ]]; then
    gradle_args+=("-PABI_FILTERS=${ABI_FILTERS}")
    log "Using ABI_FILTERS=${ABI_FILTERS}"
  fi

  local sign_enabled=false
  local gradle_task=""
  case "$MODE" in
    fdroid)
      log "Building fdroid release"
      gradle_task="assembleFdroidRelease"
      ;;
    playstore)
      log "Building playstore release (unsigned)"
      gradle_task="assemblePlaystoreRelease"
      ;;
    playstore-signed|signed)
      log "Building playstore release (signed)"
      gradle_task="assemblePlaystoreRelease"
      sign_enabled=true
      ;;
    fdroid-signed)
      log "Building fdroid release (signed)"
      gradle_task="assembleFdroidRelease"
      sign_enabled=true
      ;;
  esac

  if [[ "$sign_enabled" == "false" ]]; then
    (cd "$APP_DIR" && ./gradlew "$gradle_task" "${gradle_args[@]}")
    return
  fi

  local keystore_file key_alias keystore_password key_password
  keystore_file="${KEYSTORE_FILE:-$ROOT_DIR/.keys/release.jks}"

  if [[ ! -f "$keystore_file" ]]; then
    if [[ -t 0 ]]; then
      local keystore_input
      read -r -p "Keystore path [$keystore_file]: " keystore_input
      keystore_file="${keystore_input:-$keystore_file}"
    fi
  fi
  [[ -f "$keystore_file" ]] || die "keystore file not found: $keystore_file"
  export KEYSTORE_FILE="$keystore_file"

  prompt_env KEYSTORE_PASSWORD "Enter keystore password" true
  prompt_env KEY_ALIAS "Enter key alias" false
  prompt_env KEY_PASSWORD "Enter key password" true

  key_alias="$KEY_ALIAS"
  keystore_password="$KEYSTORE_PASSWORD"
  key_password="$KEY_PASSWORD"

  log "Signing keystore=$keystore_file alias=$key_alias"
  (cd "$APP_DIR" && ./gradlew "$gradle_task" "${gradle_args[@]}" \
    -Pandroid.injected.signing.store.file="$keystore_file" \
    -Pandroid.injected.signing.store.password="$keystore_password" \
    -Pandroid.injected.signing.key.alias="$key_alias" \
    -Pandroid.injected.signing.key.password="$key_password")
}

print_outputs() {
  log "APK outputs:"
  find "$APP_DIR/app/build/outputs/apk" -type f -name '*.apk' | sort
}

main() {
  setup_env
  init_submodules
  prepare_libhevtun
  prepare_libv2ray
  write_local_properties
  run_gradle_build
  print_outputs
}

main "$@"
