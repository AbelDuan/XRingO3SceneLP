#!/usr/bin/env bash
# ============================================================
#  test_sync_skip.sh —— 离线验证「升级时覆盖什么、保留什么」（SYNC_SKIP）
# ------------------------------------------------------------
#  背景（2026-09-17）：升级语义从「继承、绝不覆盖」改成
#  「除应用/游戏的线程表外一律直接覆盖」。这条语义只体现在
#  lib/util.sh 的 SYNC_SKIP 上，而它是**静默生效**的 ——
#  写错了只会在设备上表现为「某些文件莫名回退」，极难发现。
#  所以这里在沙盒里拿**真实的方案目录**跑一遍真函数，断言逐文件的结果。
#
#  用法： bash test_sync_skip.sh        （在仓库根目录跑）
# ============================================================
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 两份布局都要能跑：
#   开发树    <repo>/test_sync_skip.sh         → 模块在 <repo>/module/SceneO3Tuner
#   开源仓库  <repo>/tools/test_sync_skip.sh   → 仓库根**就是**模块根（脚本在 tools/ 下）
if [ "$(basename "$ROOT")" = "tools" ]; then ROOT="$(dirname "$ROOT")"; fi
if [ -d "$ROOT/module/SceneO3Tuner" ]; then MOD="$ROOT/module/SceneO3Tuner"; else MOD="$ROOT"; fi
SRC="$MOD/Config/4+4+2/O3/sweet_bal"
SANDBOX="$ROOT/.test_sync_skip"
SCENE="$SANDBOX/scene"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实得 [$2]）"; fi; }

[ -d "$SRC" ] || { echo "找不到方案目录: $SRC"; exit 2; }

echo "== 准备沙盒 =="
rm -rf "$SANDBOX"; mkdir -p "$SCENE/features"
# 方案源 → 沙盒 Scene 目录（模拟「设备上已有一份配置」）
cp -f "$SRC"/*.json "$SRC"/*.sh "$SRC"/*.txt "$SCENE/" 2>/dev/null
cp -f "$SRC"/features/*.conf "$SCENE/features/" 2>/dev/null
# 把这几个改写成「设备侧特有」的内容，用来判断同步有没有动它们
for f in profile.json _Apps.json _Games.json _ELP.json _Camera.json manifest.json powercfg.sh; do
    case "$f" in
      profile.json|manifest.json|_Apps.json|_Games.json|_ELP.json|_Camera.json)
        printf '{"device":"%s"}\n' "$f" > "$SCENE/$f" ;;
      powercfg.sh)
        printf '#!/system/bin/sh\n# device\n' > "$SCENE/$f" ;;
    esac
done
printf 'DEVICE:threads.json\n'        > "$SCENE/threads.json"
printf 'DEVICE:threads_games.json\n'  > "$SCENE/threads_games.json"
printf 'device-cpuset\n'             > "$SCENE/features/cpuset.conf"

# 载入真实函数库，然后在沙盒里跑（stub 掉只有真机才有的那几个）
. "$MOD/lib/util.sh"
SCENE_DIR="$SCENE"
STATE_DIR="$SANDBOX/state"
LOG_FILE="$SANDBOX/state/log.txt"
mkdir -p "$STATE_DIR"
get_package_uid()       { echo 10321; }
ensure_scene_dir_perm() { :; }
fix_perm()              { :; }
dir_x_ok()              { return 0; }
write_replace()         { cp -f "$1" "$2"; }
log()                   { :; }
log_quiet()             { :; }

md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
same(){ [ "$(md5 "$1")" = "$(md5 "$2")" ]; }

# ---------- 1) 默认（升级路径）：保留 threads*，其余覆盖 ----------
echo "== 1) 默认 SYNC_SKIP：覆盖其余、保留应用/游戏线程表 =="
n=$(sync_scheme "$SRC" 2>/dev/null | tail -1)
echo "  同步文件数 = $n"
for f in profile.json manifest.json _Camera.json _Apps.json _Games.json _ELP.json description.txt powercfg.sh; do
    if same "$SRC/$f" "$SCENE/$f"; then ok "$f 已覆盖"; else bad "$f 未覆盖"; fi
done
for f in cpuset.conf env.conf fas.conf limiter.conf refresh_rate.conf; do
    if same "$SRC/features/$f" "$SCENE/features/$f"; then ok "features/$f 已覆盖"; else bad "features/$f 未覆盖"; fi
done
for f in threads.json threads_games.json; do
    if [ "$(cat "$SCENE/$f")" = "DEVICE:$f" ]; then ok "$f 未被动（保留）"; else bad "$f 被覆盖了（不该）"; fi
done
# 文件数 = 源里 10 个 + features 5 个 − 跳过的 2 个 = 13
check "同步计数" "$n" "13"
# verify_synced 必须判过（否则 sync_scheme 会返回非数字）
case "$n" in ''|*[!0-9]*) bad "sync_scheme 返回非数字（自检未过）" ;; *) ok "同步后自检通过" ;; esac

# ---------- 2) SYNC_SKIP 置空：全量覆盖（手动「传递预案」那种） ----------
echo "== 2) SYNC_SKIP= 应恢复全量覆盖 =="
n2=$(SYNC_SKIP= sync_scheme "$SRC" 2>/dev/null | tail -1)
echo "  同步文件数 = $n2"
check "同步计数" "$n2" "15"
for f in threads.json threads_games.json; do
    if same "$SRC/$f" "$SCENE/$f"; then ok "$f 已覆盖（全量模式）"; else bad "$f 仍未覆盖（全量模式失效）"; fi
done

# ---------- 3) sync_skip 判定函数本身 ----------
echo "== 3) sync_skip() 判定 =="
if sync_skip threads.json; then ok "threads.json → 跳过"; else bad "threads.json 未判为跳过"; fi
if sync_skip threads_games.json; then ok "threads_games.json → 跳过"; else bad "threads_games.json 未判为跳过"; fi
if sync_skip profile.json; then bad "profile.json 被判为跳过（不该）"; else ok "profile.json → 不跳过"; fi
if sync_skip _Games.json; then bad "_Games.json 被判为跳过（不该）"; else ok "_Games.json → 不跳过"; fi
SYNC_SKIP=""; if sync_skip threads.json; then bad "置空后仍跳过"; else ok "置空后不跳过任何文件"; fi

# ---------- 4) verify_synced 也必须认这个清单 ----------
#  它的 md5 比对里含 _Apps.json / _Games.json 等，若不同步跳过就会出现
#  「明明按设计没覆盖、自检却报『与源 md5 不一致』」→ sync_scheme 返回非数字 → 安装报异常。
echo "== 4) verify_synced 对 SYNC_SKIP 的处理 =="
printf '{"device":"diff"}\n' > "$SCENE/_Apps.json"
SYNC_SKIP="_Apps.json"
out=$(verify_synced "$SRC")
if [ -z "$out" ]; then ok "跳过 _Apps.json 后自检通过"; else bad "自检未忽略跳过项：$out"; fi
SYNC_SKIP=""
out=$(verify_synced "$SRC")
case "$out" in *"_Apps.json"*) ok "不跳过时能报出 _Apps.json 不一致（说明上一断言不是假通过）" ;;
                *) bad "不跳过也没报错：[$out]" ;; esac

echo
echo "===== 通过 $PASS / 失败 $FAIL ====="
[ "$FAIL" -eq 0 ] || exit 1
