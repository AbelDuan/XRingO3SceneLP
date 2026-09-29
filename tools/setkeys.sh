#!/system/bin/sh
# setkeys.sh <source_value> [dynamic_true_false]
# 在 init mount ns 下运行：nsenter -t 1 -m sh setkeys.sh <value>
G=/data/data/com.omarea.vtools/shared_prefs/global.xml
T=/data/adb/SceneO3LP/gk.new
V="$1"
DYN="${2:-true}"
[ -n "$V" ] || { echo "ERR 缺少参数"; exit 1; }
[ -f "$G" ] || { echo "ERR global.xml 不存在"; exit 1; }

cp -af "$G" "$T.bak" 2>/dev/null

# scene_profile_source (string)
if grep -q 'name="scene_profile_source"' "$G"; then
    sed "s|name=\"scene_profile_source\">[^<]*<|name=\"scene_profile_source\">$V<|" "$G" > "$T"
else
    sed "s|</map>|    <string name=\"scene_profile_source\">$V</string>\n</map>|" "$G" > "$T"
fi
[ -s "$T" ] && cp -f "$T" "$G" && rm -f "$T"

# dynamic_control (boolean)
if grep -q 'name="dynamic_control"' "$G"; then
    sed "s|name=\"dynamic_control\" value=\"[^\"]*\"|name=\"dynamic_control\" value=\"$DYN\"|" "$G" > "$T"
else
    sed "s|</map>|    <boolean name=\"dynamic_control\" value=\"$DYN\" />\n</map>|" "$G" > "$T"
fi
[ -s "$T" ] && cp -f "$T" "$G" && rm -f "$T"

uid=$(grep -m1 "^com.omarea.vtools " /data/system/packages.list | cut -d' ' -f2)
[ -n "$uid" ] && chown "$uid:$uid" "$G" 2>/dev/null
chmod 0660 "$G" 2>/dev/null

now=$(sed -n 's|.*name="scene_profile_source">\([^<]*\)<.*|\1|p' "$G" | head -1)
dyn=$(sed -n 's|.*name="dynamic_control" value="\([^"]*\)".*|\1|p' "$G" | head -1)
echo "after_write: source=${now:-<无>} dynamic=${dyn:-<无>}"
