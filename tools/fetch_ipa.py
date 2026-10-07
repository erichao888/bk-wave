# -*- coding: utf-8 -*-
"""下载 CI artifact（未签名 ipa）并复核 Info.plist / 图标 / Mach-O。
用法：python tools/fetch_ipa.py <run_id>
产物落到 build/ 下。"""
import io
import json
import os
import re
import subprocess
import sys
import urllib.request
import zipfile


def token():
    url = subprocess.check_output(["git", "remote", "get-url", "origin"], text=True).strip()
    m = re.search(r"https://[^:]+:([^@]+)@", url)
    return m.group(1)


def api(url, raw=False):
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + token(),
        "Accept": "application/vnd.github+json",
        "User-Agent": "bk-wave-fetch",
    })
    with urllib.request.urlopen(req) as r:
        return r.read() if raw else json.loads(r.read().decode())


def main():
    run_id = sys.argv[1]
    arts = api(f"https://api.github.com/repos/erichao888/bk-wave/actions/runs/{run_id}/artifacts")
    items = arts.get("artifacts", [])
    if not items:
        print("无 artifact"); sys.exit(1)
    a = items[0]
    print("artifact:", a["name"], a["size_in_bytes"], "bytes")
    blob = api(a["archive_download_url"], raw=True)

    os.makedirs("build", exist_ok=True)
    zf = zipfile.ZipFile(io.BytesIO(blob))
    names = zf.namelist()
    print("zip 内:", names)
    ipa_bytes = None
    ipa_name = None
    for n in names:
        if n.endswith(".ipa"):
            ipa_bytes = zf.read(n)
            ipa_name = os.path.basename(n)
            break
        if n.endswith(".zip"):
            inner = zipfile.ZipFile(io.BytesIO(zf.read(n)))
            for m in inner.namelist():
                if m.endswith(".ipa"):
                    ipa_bytes = inner.read(m)
                    ipa_name = os.path.basename(m)
                    break
    if ipa_bytes is None:
        print("没找到 ipa"); sys.exit(1)
    out = os.path.join("build", ipa_name)
    with open(out, "wb") as f:
        f.write(ipa_bytes)
    print("已保存:", out, len(ipa_bytes), "bytes")

    # ---- 解包 ipa 复核 ----
    ipa = zipfile.ZipFile(io.BytesIO(ipa_bytes))
    appdir = [n for n in ipa.namelist() if n.endswith(".app/")][0].rstrip("/")
    app = appdir + "/"
    plist_raw = ipa.read(app + "Info.plist")
    # 二进制 plist 里捞关键字段（不引第三方库，直接搜字节）
    def has(s):
        return s.encode("utf-8") if isinstance(s, str) else s
    checks = {
        "版本 1.0.4": b"1.0.4",
        "Bundle ID com.benka.bkwave": b"com.benka.bkwave",
        "显示名 bk波剪": "bk波剪".encode("utf-8"),
        "PRODUCT_NAME bkWave(ASCII)": b"bkWave",
    }
    ok = True
    for k, v in checks.items():
        hit = v in plist_raw
        print(("  ✅ " if hit else "  ❌ ") + k)
        ok = ok and hit
    # 图标进包
    icons = [n for n in ipa.namelist() if "AppIcon" in n] + \
            [n for n in ipa.namelist() if n.endswith("Assets.car")]
    print("图标相关:", [os.path.basename(n) for n in icons])
    # Mach-O 主程序
    macho = app + "bkWave"
    try:
        head = ipa.read(macho)[:4]
        print("Mach-O magic:", head.hex(), "✅" if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xfb\xfa\xed\xfe") else "❌")
    except KeyError:
        print("❌ 主程序不存在"); ok = False
    print("结论:", "全部通过" if ok else "有失败项")


if __name__ == "__main__":
    main()
