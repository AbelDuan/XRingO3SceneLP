#!/system/bin/sh
# SceneO3LP · 开机推送（等 Scene 数据目录/包管理就绪后再灌配置）
MODDIR=${0%/*}
(sleep 25
    [ -d /data/data/com.omarea.vtools/files ] && \
    MODDIR="$MODDIR" sh "$MODDIR/push.sh" boot
) &
