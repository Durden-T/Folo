#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Folo"

cd "$ROOT_DIR"

# 目标：本机可安装/可双击的 macOS 构建产物（不用于分发）。
# 说明：本仓库的 Forge 配置对 darwin 会生成 zip/dmg；对 mas 会生成 pkg（需要证书）。
# 为了避免“没有证书导致 codesign 失败”，这里默认使用 ad-hoc 签名（identity='-').
# 额外：Finder 启动时可能会因为签名/资源不一致被系统直接 Kill（表现为“闪退”），所以这里会做 deep 重签名。

export OSX_SIGN_IDENTITY="${OSX_SIGN_IDENTITY:--}"
unset APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID || true

echo "[build_mac] repo: $ROOT_DIR"
echo "[build_mac] OSX_SIGN_IDENTITY=$OSX_SIGN_IDENTITY (ad-hoc)"

if ! command -v pnpm >/dev/null 2>&1; then
  echo "[build_mac] pnpm 未安装，先安装 pnpm 或启用 corepack" >&2
  echo "[build_mac] 例如：corepack enable" >&2
  exit 1
fi

if [ ! -d "$ROOT_DIR/node_modules" ]; then
  echo "[build_mac] node_modules 缺失，先执行 pnpm install（首次会较慢）"
  pnpm -C "$ROOT_DIR" install
fi

pnpm -C apps/desktop run build:electron

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="x64" ;;
  *) ARCH="$ARCH_RAW" ;;
esac

ZIP_DIR="$ROOT_DIR/apps/desktop/out/make/zip/darwin/$ARCH"
ZIP_PATH=""
DMG_PATH=""

if [ -d "$ZIP_DIR" ]; then
  ZIP_PATH="$(ls -1 "$ZIP_DIR"/*"macos-$ARCH".zip 2>/dev/null | head -n 1 || true)"
fi
DMG_PATH="$(ls -1 "$ROOT_DIR/apps/desktop/out/make/"*"-macos-$ARCH".dmg 2>/dev/null | head -n 1 || true)"

if ! command -v codesign >/dev/null 2>&1; then
  echo "[build_mac] 未找到 codesign，无法自动重签名（可能仍会闪退）" >&2
  echo "[build_mac] 产物：$ZIP_PATH" >&2
  echo "[build_mac] 产物：$DMG_PATH" >&2
  exit 0
fi

TMP_DIR="$(mktemp -d)"
MOUNT_DIR=""
cleanup() {
  rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}

detach_if_mounted() {
  if [ -n "${MOUNT_DIR:-}" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}

trap 'detach_if_mounted; cleanup' EXIT

if [ -n "$ZIP_PATH" ] && [ -f "$ZIP_PATH" ]; then
  echo "[build_mac] 对 zip 内的 .app 执行 ad-hoc deep 重签名：$ZIP_PATH"
  unzip -q "$ZIP_PATH" -d "$TMP_DIR/zip"
  if [ ! -d "$TMP_DIR/zip/$APP_NAME.app" ]; then
    echo "[build_mac] zip 内未找到 $APP_NAME.app：$ZIP_PATH" >&2
    exit 1
  fi
  xattr -dr com.apple.quarantine "$TMP_DIR/zip/$APP_NAME.app" >/dev/null 2>&1 || true
  codesign --force --deep --sign "$OSX_SIGN_IDENTITY" "$TMP_DIR/zip/$APP_NAME.app"
  codesign --verify --deep --strict "$TMP_DIR/zip/$APP_NAME.app"
  ditto -c -k --sequesterRsrc --keepParent "$TMP_DIR/zip/$APP_NAME.app" "$ZIP_PATH"
else
  echo "[build_mac] 未找到 zip 产物（跳过）：$ZIP_DIR" >&2
fi

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"

if [ -w "$INSTALL_DIR" ]; then
  echo "[build_mac] 目标安装路径：$INSTALL_PATH"
else
  echo "[build_mac] $INSTALL_DIR 不可写，改为安装到：$ROOT_DIR/apps/desktop/out/make/$APP_NAME.app" >&2
  INSTALL_DIR="$ROOT_DIR/apps/desktop/out/make"
  INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"
fi

if [ -n "$DMG_PATH" ] && [ -f "$DMG_PATH" ]; then
  echo "[build_mac] 从 dmg 提取并安装：$DMG_PATH"
  MOUNT_DIR="$TMP_DIR/mount"
  mkdir -p "$MOUNT_DIR"
  hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null

  if [ ! -d "$MOUNT_DIR/$APP_NAME.app" ]; then
    echo "[build_mac] dmg 内未找到 $APP_NAME.app：$DMG_PATH" >&2
    exit 1
  fi

  rm -rf "$INSTALL_PATH" >/dev/null 2>&1 || true
  ditto "$MOUNT_DIR/$APP_NAME.app" "$INSTALL_PATH"
  xattr -dr com.apple.quarantine "$INSTALL_PATH" >/dev/null 2>&1 || true
  codesign --force --deep --sign "$OSX_SIGN_IDENTITY" "$INSTALL_PATH"
  codesign --verify --deep --strict "$INSTALL_PATH"
  detach_if_mounted
  MOUNT_DIR=""
elif [ -n "$ZIP_PATH" ] && [ -f "$ZIP_PATH" ]; then
  echo "[build_mac] dmg 不存在，改用 zip 安装"
  rm -rf "$TMP_DIR/install" && mkdir -p "$TMP_DIR/install"
  unzip -q "$ZIP_PATH" -d "$TMP_DIR/install"
  rm -rf "$INSTALL_PATH" >/dev/null 2>&1 || true
  ditto "$TMP_DIR/install/$APP_NAME.app" "$INSTALL_PATH"
  xattr -dr com.apple.quarantine "$INSTALL_PATH" >/dev/null 2>&1 || true
  codesign --force --deep --sign "$OSX_SIGN_IDENTITY" "$INSTALL_PATH"
  codesign --verify --deep --strict "$INSTALL_PATH"
else
  echo "[build_mac] 未找到可用于安装的 dmg/zip 产物" >&2
  exit 1
fi

echo "[build_mac] 完成。产物通常在：apps/desktop/out/make/"
echo "[build_mac] 已安装：$INSTALL_PATH"

AUTO_OPEN="${AUTO_OPEN:-1}"
if [ "$AUTO_OPEN" = "1" ]; then
  echo "[build_mac] 自动启动：open -a \"$INSTALL_PATH\""
  if ! open -a "$INSTALL_PATH"; then
    echo "[build_mac] 自动启动失败，可手动执行：open -n \"$INSTALL_PATH\"" >&2
  fi
else
  echo "[build_mac] 跳过自动启动（AUTO_OPEN=$AUTO_OPEN），可手动执行：open -n \"$INSTALL_PATH\""
fi
