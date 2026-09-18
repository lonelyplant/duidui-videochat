#!/usr/bin/env python3
"""解析蒲公英 appKey —— 供 CI 注入 App 内「检测更新」（apiv2/app/check 需要它）。

三路候选，按序尝试，**并用 apiv2/app/check 实证**：
  ① `PGYER_APP_KEY` 环境变量显式指定（仓库 Variables 覆盖，最高优先）
  ② 本平台**公开下载页** SSR HTML 里的 `agKey`（零凭据，实测可取）
  ③ `apiv2/app/listMy`（需 _api_key）按 buildType + 包名/应用名关键字筛

为什么每个候选都要「实证」：公开页里那个字段叫 `agKey`，而 check 接口要的参数叫
`appKey`，**命名不同、是否等价未经证实**。所以真调一次 check，只有 `code=0` 且拿回
非空 `buildVersion` 才算数 —— 拿错 key 会让 App 读到**另一个平台**的版本号与包大小。

用法：
    PGYER_API_KEY=xxx python3 scripts/resolve_pgyer_appkey.py --type ios

约定：
  · 成功时把 appKey 打到 **stdout 且只有这一行**，方便 shell 直接取值；
  · 诊断信息（候选、实证结果、告警）全部打到 stderr，不污染 stdout；
  · 失败时 stdout 为空、退出码非 0，CI 侧据此降级为「不注入」，构建照常继续。

公开页短链不写死在本脚本/源码里（仓库公开后任何人可读，别暴露应用入口）：
由 CI 以环境变量 PGYER_SHORTCUT_ANDROID / PGYER_SHORTCUT_IOS 传入
（真值放 GitHub Secrets；缺失时跳过公开页这一路，靠 ①/③ 仍可解析）。

凭据说明：
  · appKey / agKey 都**不是**敏感凭据 —— 公开下载页的 HTML 里就明文写着；
  · `_api_key` 是【账号级】凭据（可上传/修改/删除你的应用），本脚本只在 HTTP 请求里用它，
    绝不打印、绝不写文件（只打印候选 key 的前 8 位便于对账）。
"""
import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

CHECK_URL = "https://www.pgyer.com/apiv2/app/check"
LIST_URL = "https://www.pgyer.com/apiv2/app/listMy"
# 蒲公英文档：buildType 1=iOS，2=Android
TYPE_CODE = {"ios": 1, "android": 2}
# 实证时用的版本号：传一个一定比线上旧的版本即可（check 只做「有没有新版」的比较）
PROBE_VERSION = "1.0.0"
UA = ("Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")


def _post(url, fields, timeout=30):
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=data, headers={
        "User-Agent": UA,
        "Content-Type": "application/x-www-form-urlencoded",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def _get_json(url, fields, timeout=30):
    req = urllib.request.Request(
        url + "?" + urllib.parse.urlencode(fields),
        headers={"User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def agkey_from_page(shortcut):
    """从公开下载页的 SSR HTML 里取 agKey。返回 (agKey, html 字节数)。"""
    req = urllib.request.Request(f"https://www.pgyer.com/{shortcut}",
                                 headers={"User-Agent": UA,
                                          "Accept": "text/html,application/xhtml+xml"})
    with urllib.request.urlopen(req, timeout=30) as r:
        html = r.read().decode("utf-8", "replace")
    hits = re.findall(r"agKey[\"'\s:=]{1,4}([0-9a-fA-F]{32})", html)
    return (hits[0] if hits else ""), len(html)


def apps_from_listmy(api_key):
    """listMy 的 data 结构在不同账号/版本下见过「数组」与「对象里套数组」两种，都要兼容。

    ⚠️ 实测踩过：只按数组解时 `data` 是对象 → 静默得到「0 个应用」，
    看起来像「账号下没有应用」，其实是解析写窄了。
    """
    for how, call in (("POST", _post), ("GET", _get_json)):
        try:
            j = call(LIST_URL, {"_api_key": api_key, "page": 1})
        except Exception as e:
            print(f"listMy({how}) 请求失败：{type(e).__name__}: {e}", file=sys.stderr)
            continue
        if j.get("code") != 0:
            print(f"listMy({how}) 返回 code={j.get('code')} "
                  f"message={j.get('message')}", file=sys.stderr)
            continue
        data = j.get("data")
        if isinstance(data, list):
            return data
        if isinstance(data, dict):
            for v in data.values():  # 兼容 {"list": [...]} / {"apps": [...]} 之类
                if isinstance(v, list):
                    return v
        print(f"listMy({how}) code=0，但 data 里找不到列表"
              f"（data 类型={type(data).__name__}）", file=sys.stderr)
    return []


def verify(api_key, app_key):
    """真调一次 check：只有 code=0 且拿到非空 buildVersion，才说明这个 key 是对的。"""
    try:
        j = _post(CHECK_URL, {"_api_key": api_key, "appKey": app_key,
                              "buildVersion": PROBE_VERSION})
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"
    if j.get("code") != 0:
        return False, f"code={j.get('code')} {j.get('message') or ''}".strip()
    ver = str((j.get("data") or {}).get("buildVersion") or "").strip()
    if not ver:
        return False, "code=0 但 buildVersion 为空"
    return True, f"OK，线上 buildVersion={ver}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--type", choices=["ios", "android"],
                    help="目标平台；不传则跳过公开页那一路，只在 listMy 结果里按名字匹配")
    ap.add_argument("--key-contains", default="duidui",
                    help="匹配包名/应用名的关键字（大小写不敏感）")
    args = ap.parse_args()

    api_key = (os.environ.get("PGYER_API_KEY") or "").strip()
    want_type = TYPE_CODE.get(args.type) if args.type else None

    candidates = []  # [(来源说明, appKey)]

    # ① 显式覆盖
    override = (os.environ.get("PGYER_APP_KEY") or "").strip()
    if override:
        candidates.append(("显式 PGYER_APP_KEY 环境变量", override))

    # ② 公开页 agKey（零凭据）。短链只能来自环境变量（Secrets 注入），源码不落值。
    if args.type:
        env_name = f"PGYER_SHORTCUT_{args.type.upper()}"
        shortcut = (os.environ.get(env_name) or "").strip()
        if not shortcut:
            print(f"未设置 {env_name} —— 跳过公开页这一路（可用 ①/③ 兜底）",
                  file=sys.stderr)
        else:
            try:
                key, size = agkey_from_page(shortcut)
                if key:
                    candidates.append((f"公开页 /{shortcut} 的 agKey", key))
                else:
                    print(f"公开页 /{shortcut} 里没找到 agKey（页面 {size} 字节）",
                          file=sys.stderr)
            except Exception as e:
                print(f"公开页 /{shortcut} 读取失败：{type(e).__name__}: {e}",
                      file=sys.stderr)

    # ③ listMy
    if api_key:
        apps = apps_from_listmy(api_key)
        print(f"listMy 取到 {len(apps)} 个应用：", file=sys.stderr)
        for a in apps:
            print("  - name={} type={} id={} ver={} key={}…".format(
                a.get("buildName"), a.get("buildType"), a.get("buildIdentifier"),
                a.get("buildVersion"),
                str(a.get("appKey") or "")[:8]), file=sys.stderr)
        needle = args.key_contains.lower()
        for a in apps:
            k = str(a.get("appKey") or "").strip()
            if not k:
                continue
            ident = str(a.get("buildIdentifier") or "").lower()
            name = str(a.get("buildName") or "").lower()
            if needle and needle not in ident and needle not in name:
                continue
            bt = a.get("buildType")
            # ⚠️ 类型明显不符就直接跳过，**绝不跨平台兜底采用**：
            #    拿错 key 会让 App 的版本号/包大小/下载入口全指错应用，比「没有 key」更糟。
            if want_type is not None and bt is not None and int(bt) != want_type:
                continue
            candidates.append(
                (f"listMy type={bt} id={a.get('buildIdentifier')}", k))
    else:
        print("PGYER_API_KEY 未配置 —— 跳过 listMy，且无法对候选做实证", file=sys.stderr)

    if not candidates:
        print("没有任何 appKey 候选 —— App 端按构建期注入的标识降级（未注入则隐藏对应入口）。",
              file=sys.stderr)
        return 1

    # 去重后逐个实证，第一个通过的采用
    seen = set()
    picked = ""
    for src, key in candidates:
        if key in seen:
            continue
        seen.add(key)
        if not api_key:
            print(f"候选 [{src}] {key[:8]}… —— 无 _api_key，无法实证，直接采用",
                  file=sys.stderr)
            picked = key
            break
        ok, why = verify(api_key, key)
        print(f"候选 [{src}] {key[:8]}… → {why}", file=sys.stderr)
        if ok:
            picked = key
            break

    if not picked:
        print("所有候选都没通过 check 实证 —— 不做跨平台兜底，App 端按注入情况降级。",
              file=sys.stderr)
        return 1

    sys.stdout.write(picked + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
