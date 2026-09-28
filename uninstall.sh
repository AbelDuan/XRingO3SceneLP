#!/system/bin/sh
# SceneO3LP 卸载：Scene 里的配置是我们灌的，卸载后手动在 Scene 里切回任意官方方案即可
rm -f /data/local/tmp/scene_o3_lp.log 2>/dev/null
umount /sys/class/thermal/thermal_message/temp_state 2>/dev/null
umount /sys/class/thermal/thermal_message/market_download_limit 2>/dev/null
exit 0
