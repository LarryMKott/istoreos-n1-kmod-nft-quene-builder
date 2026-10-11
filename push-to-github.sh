#!/bin/bash
# =============================================================================
#  把本地仓库推送到 GitHub
#
#  本机 github.com 直连不通（沙箱代理不透传），请在「有正常网络的机器」上执行本脚本，
#  或在能访问 github.com 的环境（如 N1 旁路由代理）下执行。
#
#  用法：
#     bash push-to-github.sh <你的 GitHub PAT>
#     或先 export GITHUB_TOKEN=xxx 再执行
# =============================================================================
set -e

REPO_URL="https://github.com/LarryMKott/istoreos-n1-kmod-nft-quene-builder.git"
BRANCH="main"

TOKEN="${1:-${GITHUB_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
    echo "[i] 未提供 token，将使用系统 git 凭据（可能弹窗或失败）"
    AUTH_URL="$REPO_URL"
else
    AUTH_URL="https://${TOKEN}@github.com/LarryMKott/istoreos-n1-kmod-nft-quene-builder.git"
fi

cd "$(dirname "$0")"

# 保证是干净已提交状态
if [ -d .git ]; then
    echo "[i] 当前提交:"
    git log --oneline -1
    if [ -n "$(git status --porcelain)" ]; then
        echo "[!] 有未提交改动，先提交"
        git add -A
        git commit -m "chore: update" || true
    fi
else
    echo "[x] 当前目录不是 git 仓库，请在仓库根目录执行"; exit 1
fi

echo "[i] 设置远程 origin"
git remote remove origin 2>/dev/null || true
git remote add origin "$AUTH_URL"

echo "[i] 重命名分支为 $BRANCH（若不是）"
git branch -M "$BRANCH"

echo "[i] 推送..."
git push -u origin "$BRANCH"

# 把带 token 的 URL 换回干净 URL，避免 token 留在 .git/config
git remote set-url origin "$REPO_URL"

echo
echo "[✓] 推送完成: $REPO_URL"
echo
echo "下一步："
echo "  1. 到仓库 Actions 页 → 'Publish builder image to GHCR' → Run workflow（约 5-8 分钟）"
echo "  2. 跑 'Build kmod-nft-queue for iStoreOS (Phicomm N1)'（首次 2-4 小时）"
echo "  3. 在 Artifacts 下载 kmod-nft-queue-*.zip"
