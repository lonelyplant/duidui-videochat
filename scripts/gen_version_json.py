#!/usr/bin/env python3
"""生成 dist/version.json —— App 内「检测更新」的其中一路数据源。

字段：
  build / version                        本机比较用（= CI run_number）
  notes                                  更新说明（自上一个 tag 以来的提交标题）
  size_bytes_android / size_bytes_ios    安装包大小（字节）
  android_url                            蒲公英下载页（永远可用）
  android_apk_url                        安卓 APK 直链
  ios_pgyer_url                          蒲公英现签 IPA 直链（约几分钟时效，通常为空串）
  ios_github_url                         IPA 直链
  ios_trollstore                         apple-magnifier:// 一键装 scheme

⚠️ GitHub 直链基址来自 RELEASE_REPO 环境变量：CI 未配 vars.RELEASE_REPO 时会
   退化为本仓库自身（仓库公开后其 Release 资源匿名可访问，直链有效）；
   本地干跑没传时留空 —— 与其让 App 里出现「点了就报错」的按钮，不如留空，
   App 会改显示「前往下载页」。

改用脚本而不是 shell heredoc 的原因：更新说明来自 git 提交标题，可能含引号/反斜杠，
heredoc 拼 JSON 会拼出非法 JSON 甚至意外注入；json.dump 一次性解决。

用法（在仓库根目录、已 checkout、dist/ 下已有两个安装包时）：
    RUN_NUMBER=42 RELEASE_REPO=owner/repo python3 scripts/gen_version_json.py
"""
import json
import os
import subprocess
import sys

DIST = "dist"
APK = "duidui_video.apk"
IPA = "duidui_video.ipa"
# 蒲公英应用页（「至少有地方能下」的兜底入口）：构建期由 CI 从 Secrets 注入
# （PGYER_PAGE_URL 环境变量），源码不落应用短链；未注入时留空，App 隐藏该入口。
PGYER_PAGE = (os.environ.get("PGYER_PAGE_URL") or "").strip()


def size_of(name):
    """取安装包字节数；文件不存在返回 0（App 端会把 0 当作「没拿到大小」）。"""
    try:
        return os.path.getsize(os.path.join(DIST, name))
    except OSError:
        return 0


def _git(*args):
    try:
        r = subprocess.run(["git", "-c", "core.pager=cat", *args],
                           capture_output=True, text=True, timeout=60)
        return (r.stdout or "").strip()
    except Exception as e:
        print(f"git {' '.join(args)} 失败：{type(e).__name__}: {e}", file=sys.stderr)
        return ""


def commit_notes(limit=30):
    """更新说明：上一个 tag 到 HEAD 的提交标题；没有 tag 就取最近一次提交。"""
    prev = _git("describe", "--tags", "--abbrev=0")
    rng = f"{prev}..HEAD" if prev else "HEAD"
    out = _git("log", rng, "--pretty=format:- %s")
    if not out:
        out = _git("log", "-1", "--pretty=format:- %s")
    return "\n".join(out.splitlines()[:limit])


def main():
    run = (os.environ.get("RUN_NUMBER") or "").strip()
    if not run.isdigit():
        print(f"::error::RUN_NUMBER 缺失或不是数字：{run!r}", file=sys.stderr)
        return 1

    rel = (os.environ.get("RELEASE_REPO") or "").strip()
    base = f"https://github.com/{rel}/releases/latest/download" if rel else ""
    if not rel:
        print("::warning::RELEASE_REPO 为空 → version.json 的 GitHub 直链留空"
              "（App 会改为显示「前往下载页」）")
    else:
        print(f"::notice::version.json 直链基址：{base}")

    ipa_url = f"{base}/{IPA}" if base else ""
    data = {
        "build": int(run),
        "version": f"1.0.{run}",
        "notes": commit_notes(),
        "size_bytes_android": size_of(APK),
        "size_bytes_ios": size_of(IPA),
        "android_url": PGYER_PAGE,
        "android_apk_url": f"{base}/{APK}" if base else "",
        "ios_pgyer_url": (os.environ.get("PGYER_IOS_IPA_URL") or "").strip(),
        "ios_github_url": ipa_url,
        "ios_trollstore": f"apple-magnifier://install?url={ipa_url}" if ipa_url else "",
    }

    os.makedirs(DIST, exist_ok=True)
    path = os.path.join(DIST, "version.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
