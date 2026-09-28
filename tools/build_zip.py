#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SceneO3LP 模块一键打包
用法: python tools/build_zip.py   （在仓库根执行或任意位置，自动定位仓库根）
产出: dist/SceneO3LP-<version>-<日期>.zip
规范: 全成员 LF（CRLF 铁律终检）、.sh/update-binary 755、其余 644
"""
import json, os, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODULE_FILES = ["module.prop", "service.sh", "action.sh", "push.sh",
                "customize.sh", "uninstall.sh"]
CONFIG_FILES = ["profile.json", "manifest.json", "powercfg.sh", "description.txt",
                "_Apps.json", "_Games.json", "_Camera.json", "_ELP.json"]
CONFIG_FILES = [f.strip() for f in CONFIG_FILES]      # 容错手写空格
META_FILES = ["META-INF/com/google/android/update-binary",
              "META-INF/com/google/android/updater-script"]

def main():
    prop = open(os.path.join(ROOT, "module.prop"), encoding="utf-8").read()
    ver = [l.split("=", 1)[1].strip() for l in prop.splitlines() if l.startswith("version=")][0]
    out_dir = os.path.join(ROOT, "dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "SceneO3LP-%s-20260928.zip" % ver.split()[0])

    rels = MODULE_FILES + ["Config/" + f for f in CONFIG_FILES] + META_FILES
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in rels:
            p = os.path.join(ROOT, rel.replace("/", os.sep))
            data = open(p, "rb").read().replace(b"\r\n", b"\n")
            zi = zipfile.ZipInfo(rel, date_time=(2026, 9, 28, 19, 0, 0))
            zi.external_attr = (0o755 if rel.endswith(".sh") or "update-binary" in rel
                                else 0o644) << 16
            z.writestr(zi, data, zipfile.ZIP_DEFLATED)

    # CRLF 铁律终检 + JSON 校验
    with zipfile.ZipFile(out) as z:
        crlf = [i.filename for i in z.infolist() if b"\r\n" in z.read(i.filename)]
        if crlf:
            raise SystemExit("FAIL CRLF: %s" % crlf)
        for rel in rels:
            if rel.endswith(".json"):
                json.loads(z.read(rel).decode("utf-8"))
    print("OK %s (%d bytes, %d files)" % (out, os.path.getsize(out), len(rels)))

if __name__ == "__main__":
    main()
