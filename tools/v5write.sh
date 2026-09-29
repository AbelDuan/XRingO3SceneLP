#!/system/bin/sh
# v5: 快速写入 global.xml 两键（复用 push.sh pref_set 逻辑，备份+回读校验）
# 必须在 init mount ns 下运行（nsenter -t 1 -m）
G=/data/data/com.omarea.vtools/shared_prefs/global.xml
T=/data/adb/SceneO3LP/global.xml.new
B=/data/adb/SceneO3LP/global.xml.v5bak

[ -f "$G" ] || { echo "ERR global.xml 不存在"; exit 1; }
cp -af "$G" "$B" 2>/dev/null && echo "备份 -> $B"

set_str() {
    k="$1"; w="$2"
    cur=$(sed -n "s|.*name=\"${k}\">\([^<]*\)<.*|\1|p" "$G" | head -1)
    if [ "$cur" = "$w" ]; then echo "  $k 已是期望值"; return 0; fi
    if [ -n "$cur" ]; then
        sed "s|name=\"${k}\">[^<]*<|name=\"${k}\">${w}<|" "$G" > "$T"
    else
        sed "s|</map>|    <string name=\"${k}\">${w}</string>\n</map>|" "$G" > "$T"
    fi
    [ -s "$T" ] || { echo "ERR 生成 $k 内容失败"; return 1; }
    cp -f "$T" "$G" && rm -f "$T"
    echo "  $k -> $w"
}

set_bool() {
    k="$1"; w="$2"
    cur=$(sed -n "s|.*name=\"${k}\" value=\"\([^\"]*\)\".*|\1|p" "$G" | head -1)
    if [ "$cur" = "$w" ]; then echo "  $k 已是期望值"; return 0; fi
    if [ -n "$cur" ]; then
        sed "s|name=\"${k}\" value=\"[^\"]*\"|name=\"${k}\" value=\"${w}\"|" "$G" > "$T"
    else
        sed "s|</map>|    <boolean name=\"${k}\" value=\"${w}\" />\n</map>|" "$G" > "$T"
    fi
    [ -s "$T" ] || { echo "ERR 生成 $k 内容失败"; return 1; }
    cp -f "$T" "$G" && rm -f "$T"
    echo "  $k -> $w"
}

rc=0
set_str scene_profile_source SOURCE_SCENE_ONLINE || rc=1
set_bool dynamic_control true || rc=1

uid=$(grep -m1 "^com.omarea.vtools " /data/system/packages.list | cut -d' ' -f2)
if [ -n "$uid" ]; then
    chown "${uid}:${uid}" "$G" 2>/dev/null
    chmod 0660 "$G" 2>/dev/null
fi

echo "--回读--"
grep -o "scene_profile_source[^<]*<[^<]*" "$G" || { echo "source 回读 ❌"; rc=1; }
grep -o "dynamic_control[^/]*" "$G" || { echo "dynamic_control 回读 ❌"; rc=1; }
exit $rc
