#!/system/bin/sh
# SceneO3LP · action 按钮：重灌配置到 Scene 并显示当前方案身份
MODDIR=${0%/*}
echo "=== SceneO3LP：推送 O1 官方移植方案（LP）到 Scene ==="
MODDIR="$MODDIR" sh "$MODDIR/push.sh" action
RC=$?

MP=/data/data/com.omarea.vtools/files/manifest.json
if [ -f "$MP" ]; then
    V=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MP" | head -1)
    C=$(sed -n 's/.*"versionCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$MP" | head -1)
    echo "--- Scene 当前方案身份 ---"
    echo "  author: SCENE9（调节页显示为「Scene」）"
    echo "  version: ${V:-?}（调节页显示为「🌍 Version: ${V}」）"
    echo "  versionCode: ${C:-?}"
    [ "$V" = "LP" ] && echo "✅ 命名正常" || echo "⚠ version 不是 LP，请重跑本按钮"
fi
exit $RC
