#!/usr/bin/env bash
# DeepSeek
# =============================================================================
# 自动获取每个 Minecraft 版本中最新 NeoForge 安装器，并生成离线版本
#
# 依赖：bash 4+、curl、jq、java
# 用法：bash neoforge-offline-latest.sh [输出目录]
# 默认输出目录：./neoforge-offline-latest
#
# 注意：请务必用 bash 执行（不要用 sh），否则 set -o pipefail 会报错。
# =============================================================================

set -euo pipefail

# ---------- 可配置变量 ----------
BASE_API="https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge"
BASE_DOWNLOAD="https://maven.neoforged.net/releases/net/neoforged/neoforge"

# ---------- 检查依赖 ----------
for cmd in curl jq java; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ 缺少必要命令：$cmd" >&2
        exit 1
    fi
done

# ---------- 准备输出目录（转绝对路径，避免子 shell 中 cd 后相对路径失效）----------
OUTPUT_DIR="${1:-./neoforge-offline-latest}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)   # 关键：转为绝对路径
INSTALLER_DIR="${OUTPUT_DIR}/installers"
OFFLINE_DIR="${OUTPUT_DIR}/offline"
mkdir -p "$INSTALLER_DIR" "$OFFLINE_DIR"

# ---------- 版本比较工具 ----------
# version_gt A B ：若 A 的数字版本号大于 B，返回 0；否则返回 1
# 忽略 -beta/-alpha 等后缀，逐段按数字比较，缺失段补 0
version_gt() {
    local v1="${1%%-*}" v2="${2%%-*}"
    local IFS='.'
    local -a a=($v1) b=($v2)
    local i max=${#a[@]}
    (( ${#b[@]} > max )) && max=${#b[@]}
    for ((i=0; i<max; i++)); do
        local x=${a[i]:-0} y=${b[i]:-0}
        if (( 10#$x > 10#$y )); then return 0; fi
        if (( 10#$x < 10#$y )); then return 1; fi
    done
    return 1
}

is_prerelease() {
    echo "$1" | grep -qiE '-(beta|alpha|pre|rc|snapshot)'
}

# ---------- 获取版本列表 ----------
echo "📡 正在获取 NeoForge 版本列表..."
VERSION_JSON=$(curl -fsSL "$BASE_API")
if [[ -z "$VERSION_JSON" ]]; then
    echo "❌ 无法获取版本列表，请检查网络。" >&2
    exit 1
fi

ALL_VERSIONS=()
while IFS= read -r v; do
    [[ -n "$v" ]] && ALL_VERSIONS+=("$v")
done < <(echo "$VERSION_JSON" | jq -r '.versions[]')

if [[ ${#ALL_VERSIONS[@]} -eq 0 ]]; then
    echo "❌ 未解析到任何版本。" >&2
    exit 1
fi

echo "✅ 共发现 ${#ALL_VERSIONS[@]} 个 NeoForge 版本，开始按 Minecraft 版本分组..."

# ---------- 按 Minecraft 版本分组，每组选出最新 ----------
# key = 版本号前两段（如 "20.2"、"26.3"），value = 该组最新 NeoForge 完整版本号
declare -A LATEST_PER_MC

for VER in "${ALL_VERSIONS[@]}"; do
    MC_KEY=$(echo "$VER" | grep -oE '^[0-9]+\.[0-9]+' || true)
    [[ -z "$MC_KEY" ]] && continue

    CURRENT="${LATEST_PER_MC[$MC_KEY]:-}"

    if [[ -z "$CURRENT" ]]; then
        LATEST_PER_MC["$MC_KEY"]="$VER"
        continue
    fi

    CURRENT_PRE=false
    NEW_PRE=false
    is_prerelease "$CURRENT" && CURRENT_PRE=true
    is_prerelease "$VER"     && NEW_PRE=true

    REPLACE=false
    if $CURRENT_PRE && ! $NEW_PRE; then
        # 正式版优先于预发布版
        REPLACE=true
    elif $CURRENT_PRE && $NEW_PRE; then
        # 都是预发布版，比版本号
        version_gt "$VER" "$CURRENT" && REPLACE=true
    elif ! $CURRENT_PRE && ! $NEW_PRE; then
        # 都是正式版，比版本号
        version_gt "$VER" "$CURRENT" && REPLACE=true
    fi
    # 当前是正式版、新的是预发布版：不替换

    if $REPLACE; then
        LATEST_PER_MC["$MC_KEY"]="$VER"
    fi
done

if [[ ${#LATEST_PER_MC[@]} -eq 0 ]]; then
    echo "❌ 未能识别任何 Minecraft 版本分组。" >&2
    exit 1
fi

echo "✅ 分组完成，共识别 ${#LATEST_PER_MC[@]} 个 Minecraft 版本分支。"
echo ""
echo "📋 各 Minecraft 版本对应的最新 NeoForge："
for MC_KEY in $(printf '%s\n' "${!LATEST_PER_MC[@]}" | sort -V); do
    echo "   MC ${MC_KEY}  →  ${LATEST_PER_MC[$MC_KEY]}"
done

# ---------- 下载并生成离线安装器 ----------
SUCCESS=0
FAILED=()

for MC_KEY in $(printf '%s\n' "${!LATEST_PER_MC[@]}" | sort -V); do
    VER="${LATEST_PER_MC[$MC_KEY]}"
    echo ""
    echo "----------------------------------------"
    echo "🔧 MC ${MC_KEY} 的最新 NeoForge：$VER"

    INSTALLER_NAME="neoforge-${VER}-installer.jar"
    INSTALLER_URL="${BASE_DOWNLOAD}/${VER}/${INSTALLER_NAME}"
    INSTALLER_PATH="${INSTALLER_DIR}/${INSTALLER_NAME}"

    # 下载安装器（已存在则跳过）
    if [[ -s "$INSTALLER_PATH" ]]; then
        echo "⏭️  安装器已存在，跳过下载：$INSTALLER_PATH"
    else
        echo "⬇️  下载安装器：$INSTALLER_URL"
        if ! curl -fsSL -o "$INSTALLER_PATH" "$INSTALLER_URL"; then
            echo "❌ 下载失败，跳过该版本。" >&2
            rm -f "$INSTALLER_PATH"
            FAILED+=("MC ${MC_KEY} / NeoForge $VER (下载失败)")
            continue
        fi
        echo "✅ 下载成功。"
    fi

    # 二次保险：确认文件真实存在且非空
    if [[ ! -s "$INSTALLER_PATH" ]]; then
        echo "❌ 安装器文件不存在或为空，跳过。" >&2
        FAILED+=("MC ${MC_KEY} / NeoForge $VER (安装器文件缺失)")
        continue
    fi

    OFFLINE_OUT="${OFFLINE_DIR}/${MC_KEY}/${VER}"
    mkdir -p "$OFFLINE_OUT"

    echo "⚙️  生成离线安装器..."
    if ( cd "$OFFLINE_OUT" && java -jar "$INSTALLER_PATH" --fat-offline ); then
        echo "✅ 离线安装器生成成功：$OFFLINE_OUT"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "⚠️  --fat-offline 执行失败，尝试 --gen-offline ..."
        if ( cd "$OFFLINE_OUT" && java -jar "$INSTALLER_PATH" --gen-offline ); then
            echo "✅ 离线安装器生成成功（--gen-offline）：$OFFLINE_OUT"
            SUCCESS=$((SUCCESS + 1))
        else
            echo "❌ 离线生成失败：MC ${MC_KEY} / NeoForge $VER" >&2
            FAILED+=("MC ${MC_KEY} / NeoForge $VER (离线生成失败)")
        fi
    fi
done

# ---------- 汇总 ----------
echo ""
echo "========================================"
echo "🎉 处理完成！"
echo "   成功生成离线安装器：$SUCCESS 个（每个 MC 版本一个）"
echo "   输出目录：$OFFLINE_DIR"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "⚠️  以下条目处理失败："
    for f in "${FAILED[@]}"; do
        echo "   - $f"
    done
    exit 1
fi