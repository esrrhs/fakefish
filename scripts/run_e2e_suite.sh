#!/usr/bin/env bash
# 按清单逐条执行 E2E 用例，失败立即以非零码退出。
#
# 用法：bash scripts/run_e2e_suite.sh <清单文件>
#   例如：bash scripts/run_e2e_suite.sh scripts/e2e-main.txt
#
# 清单为纯文本：一行一个 test_*.js，空行与 # 开头的行忽略。
# 三平台 CI 与本地共用同一份清单，避免测试集合在平台间漂移。
set -u

suite="${1:-}"
if [ -z "$suite" ] || [ ! -f "$suite" ]; then
    echo "ERROR: suite file not found: '$suite'"
    echo "usage: bash scripts/run_e2e_suite.sh <suite-file>"
    exit 1
fi

while IFS= read -r t || [ -n "$t" ]; do
    case "$t" in
        ''|\#*) continue ;;
    esac
    if [ ! -f "$t" ]; then
        echo "ERROR: suite lists a missing test file: $t"
        exit 1
    fi
    echo "=== Running $t E2E Test ==="
    if ! node "$t"; then
        echo "FAILED: $t"
        exit 1
    fi
done < "$suite"

echo "=== suite passed: $suite ==="
