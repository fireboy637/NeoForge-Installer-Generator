#!/usr/bin/env bash
# =============================================================================
# 自动获取每个 Minecraft 版本中最新 NeoForge 安装器，并生成离线版本
# 依赖：curl, jq, java
# 用法：./neoforge-offline-latest-per-mc.sh [输出目录]
# 默认输出目录：./neoforge-offline-latest
# =============================================================================

set -euo pipefail

# ---------- 可配置变量 ----------
BASE_API="https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge"
BASE_DOWNLOAD="https://maven.neoforged.net/releases/net/neoforged/neoforge"
OUTPUT_DIR="${1:-./neoforge-offline-latest}"
INSTALLER_DIR="${OUTPUT_DIR}/installers"
OFFLINE_DIR="${OUTPUT_DIR}/offline"

# ---------- 检查依赖 ----------
for cmd in curl jq java; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ 缺少必要命令：$cmd" >&2
        exit 1
    fi
done

# ---------- 准备工作目录 ----------
mkdir -p "$INSTALLER_DIR" "$OFFLINE_DIR"

echo "📡 正在获取 NeoForge 版本列表..."
VERSION_JSON=$(curl -fsSL "$BASE_API")
if [[ -z "$VERSION_JSON" ]]; then
    echo "❌ 无法获取版本列表，请检查网络。" >&2
    exit 1
fi

# 提取所有版本号
mapfile -t ALL_VERSIONS < <(echo "$VERSION_JSON" | jq -r '.versions[]')
if [[ ${#ALL_VERSIONS[@]} -eq 0 ]]; then
    echo "❌ 未解析到任何版本。" >&2
    exit 1
fi

echo "✅ 共发现 ${#ALL_VERSIONS[@]} 个 NeoForge 版本，开始按 Minecraft 版本分组..."

# ---------- 按 Minecraft 版本分组，并选出每组最新 ----------
# 使用关联数组：key = "20.2" 这样的 MC 版本标识，value = 该组最新的 NeoForge 完整版本号
declare -A LATEST_PER_MC
declare -A HAS_RELEASE   # 标记该组是否已有正式版

for VER in "${ALL_VERSIONS[@]}"; do
    # 提取前两段作为 MC 版本标识（忽略 -beta 等后缀）
    MC_KEY=$(echo "$VER" | grep -oE '^[0-9]+\.[0-9]+' || true)
    [[ -z "$MC_KEY" ]] && continue

    # 判断是否为预发布版（包含 -beta, -alpha 等后缀）
    IS_PRERELEASE=false
    if echo "$VER" | grep -qiE '-(beta|alpha|pre|rc)'; then
        IS_PRERELEASE=true
    fi

    CURRENT="${LATEST_PER_MC[$MC_KEY]:-}"

    if [[ -z "$CURRENT" ]]; then
        # 该 MC 版本第一次出现
        LATEST_PER_MC["$MC_KEY"]="$VER"
        $IS_PRERELEASE || HAS_RELEASE["$MC_KEY"]=true
    else
        # 已有记录，需要比较
        CURRENT_IS_PRERELEASE=false
        if echo "$CURRENT" | grep -qiE '-(beta|alpha|pre|rc)'; then
            CURRENT_IS_PRERELEASE=true
        fi

        # 规则：正式版永远优先于预发布版；同类之间再比较版本号
        SHOULD_REPLACE=false
        if $CURRENT_IS_PRERELEASE && ! $IS_PRERELEASE; then
            SHOULD_REPLACE=true
        elif $CURRENT_IS_PRERELEASE && $IS_PRERELEASE; then
            # 都是预发布版，比较 patch 数字部分（去掉后缀）
            CUR_NUM=$(echo "$CURRENT" | sed -E 's/-.*$//' | awk -F. '{print $3+0}')
            NEW_NUM=$(echo "$VER" | sed -E 's/-.*$//' | awk -F. '{print $3+0}')
            [[ "$NEW_NUM" -gt "$CUR_NUM" ]] && SHOULD_REPLACE=true
        elif ! $CURRENT_IS_PRERELEASE && ! $IS_PRERELEASE; then
            # 都是正式版，比较 patch 数字
            CUR_NUM=$(echo "$CURRENT" | awk -F. '{print $3+0}')
            NEW_NUM=$(echo "$VER" | awk -F. '{print $3+0}')
            [[ "$NEW_NUM" -gt "$CUR_NUM" ]] && SHOULD_REPLACE=true
        fi
        # 如果 CURRENT 是正式版而 VER 是预发布版，不替换

        if $SHOULD_REPLACE; then
            LATEST_PER_MC["$MC_KEY"]="$VER"
            $IS_PRERELEASE || HAS_RELEASE["$MC_KEY"]=true
        fi
    fi
done

echo "✅ 分组完成，共识别 ${#LATEST_PER_MC[@]} 个 Minecraft 版本分支。"

# 打印分组结果，方便核对
echo ""
echo "📋 各 Minecraft 版本对应的最新 NeoForge："
for MC_KEY in $(printf '%s\n' "${!LATEST_PER_MC[@]}" | sort -V); do
    echo "   Minecraft ${MC_KEY#1.}  →  ${LATEST_PER_MC[$MC_KEY]}"
done

# ---------- 下载并生成离线安装器 ----------
SUCCESS=0
FAILED=()

for MC_KEY in $(printf '%s\n' "${!LATEST_PER_MC[@]}" | sort -V); do
    VER="${LATEST_PER_MC[$MC_KEY]}"
    echo ""
    echo "----------------------------------------"
    echo "🔧 Minecraft ${MC_KEY#1.} 的最新 NeoForge：$VER"

    INSTALLER_NAME="neoforge-${VER}-installer.jar"
    INSTALLER_URL="${BASE_DOWNLOAD}/${VER}/${INSTALLER_NAME}"
    INSTALLER_PATH="${INSTALLER_DIR}/${INSTALLER_NAME}"

    if [[ -f "$INSTALLER_PATH" ]]; then
        echo "⏭️  安装器已存在，跳过下载：$INSTALLER_PATH"
    else
        echo "⬇️  下载安装器：$INSTALLER_URL"
        if curl -fsSL -o "$INSTALLER_PATH" "$INSTALLER_URL"; then
            echo "✅ 下载成功。"
        else
            echo "❌ 下载失败，跳过该版本。" >&2
            FAILED+=("MC ${MC_KEY#1.} / NeoForge $VER (下载失败)")
            continue
        fi
    fi

    OFFLINE_OUT="${OFFLINE_DIR}/${MC_KEY#1.}/${VER}"
    mkdir -p "$OFFLINE_OUT"

    echo "⚙️  生成离线安装器..."
    if (cd "$OFFLINE_OUT" && java -jar "$INSTALLER_PATH" --fat-offline 2>&1); then
        echo "✅ 离线安装器生成成功：$OFFLINE_OUT"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "⚠️  --fat-offline 执行失败，尝试 --gen-offline..."
        if (cd "$OFFLINE_OUT" && java -jar "$INSTALLER_PATH" --gen-offline 2>&1); then
            echo "✅ 离线安装器生成成功（--gen-offline）：$OFFLINE_OUT"
            SUCCESS=$((SUCCESS + 1))
        else
            echo "❌ 离线生成失败：MC ${MC_KEY#1.} / NeoForge $VER" >&2
            FAILED+=("MC ${MC_KEY#1.} / NeoForge $VER (离线生成失败)")
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
fi