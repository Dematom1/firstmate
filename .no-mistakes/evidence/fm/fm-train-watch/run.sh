cd /Users/laszlo/.no-mistakes/worktrees/b44e88b6dda0/01M61GYJHCY1XGVKX2C322RD5E
. tests/zz-tmp-lib.sh
export FM_TEST_WATCH_BOUND=3600
for t in "$@"; do s=$(date +%s); ( $t ) ; echo "RESULT $t rc=$? $(( $(date +%s)-s ))s"; done
