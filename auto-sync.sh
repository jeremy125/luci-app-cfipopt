#!/bin/sh
# 自动同步 luci-app-cfipopt 到 GitHub (cron 调用)
# 有变更时 commit + push; 无变更时静默退出 (watchdog 模式)
set -e

REPO_DIR="/root/cfipopt-build"
REMOTE="origin"
BRANCH="main"

cd "$REPO_DIR"

# 未配置远程时静默跳过 (首次同步前)
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    exit 0
fi

git add -A

if git diff --cached --quiet; then
    # 无变更, 但可能有未推送的 commit
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse "$REMOTE/$BRANCH" 2>/dev/null || echo none)" ]; then
        git push "$REMOTE" "$BRANCH" 2>&1
    fi
    exit 0
fi

git commit -m "auto-sync: $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null
git push "$REMOTE" "$BRANCH" 2>&1
echo "synced: $(date '+%Y-%m-%d %H:%M:%S')"
