#!/usr/bin/env bash
# E2E 清单一致性校验（CI 门禁，秒级）：
#   1. 每个 test_*.js 都必须登记进 e2e-main.txt 或 e2e-bots.txt（防新增用例漏跑）；
#   2. 清单里引用的每个文件都必须真实存在（防改名/删除后留下悬空引用）。
# 任一方向不一致即非零退出。
set -u

cd "$(dirname "$0")/.." || exit 1

rc=0

for f in test_*.js; do
    if ! grep -qxF "$f" scripts/e2e-main.txt && ! grep -qxF "$f" scripts/e2e-bots.txt; then
        echo "ERROR: $f exists but is not registered in scripts/e2e-main.txt or scripts/e2e-bots.txt"
        rc=1
    fi
done

for suite in scripts/e2e-main.txt scripts/e2e-bots.txt; do
    while IFS= read -r t || [ -n "$t" ]; do
        case "$t" in
            ''|\#*) continue ;;
        esac
        if [ ! -f "$t" ]; then
            echo "ERROR: $suite references a missing file: $t"
            rc=1
        fi
    done < "$suite"
done

if [ "$rc" -eq 0 ]; then
    echo "E2E coverage check OK"
fi
exit "$rc"
