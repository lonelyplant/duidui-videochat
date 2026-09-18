#!/usr/bin/env python3
"""CI 用：给 flutter create 生成的 android/app/build.gradle 注入固定签名配置。

Flutter 脚手架的 release 构建默认用 signingConfigs.debug，它指向 runner 上
每次随机生成的 ~/.android/debug.keystore —— 每次 CI 出包签名都不同，
覆盖安装必然报「签名不一致」。这里注入固定 keystore，保证所有包签名一致、
可直接覆盖升级。重复执行幂等。

⚠️ 密钥【不进仓库】（仓库公开后任何人可读全部文件与历史）：
    keystore 与密码分别来自 GitHub Secrets
        ANDROID_KEYSTORE_BASE64    keystore 文件的 base64（一行，base64 -w0 生成）
        ANDROID_KEYSTORE_PASSWORD  keystore 密码
    本脚本把 base64 解码写成 android/app/duidui-release.keystore，
    再把签名配置注入 build.gradle（密码只存在于 runner 本地，构建结束即丢弃）。

生成/轮换密钥（本地做一次，然后更新两个 Secret）：
    keytool -genkeypair -v -keystore duidui-release.keystore -alias duidui \
        -keyalg RSA -keysize 2048 -validity 10950 -storetype PKCS12 \
        -storepass <新密码> -dname "CN=duidui"
    base64 -w0 duidui-release.keystore   # 全文粘进 Secret ANDROID_KEYSTORE_BASE64
换密钥后手机上的旧包签名不一致，需卸载重装一次。
"""
import base64
import os
import pathlib
import re
import sys

GRADLE = pathlib.Path("android/app/build.gradle")
KEYSTORE = pathlib.Path("android/app/duidui-release.keystore")
ALIAS = os.environ.get("ANDROID_KEY_ALIAS", "duidui")


def main() -> int:
    b64 = os.environ.get("ANDROID_KEYSTORE_BASE64", "").strip()
    password = os.environ.get("ANDROID_KEYSTORE_PASSWORD", "")
    if not b64 or not password:
        print("::error::缺少 Secret：ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD"
              "（Settings → Secrets and variables → Actions → New repository secret；"
              "生成方法见本脚本头部注释）")
        return 1
    try:
        KEYSTORE.write_bytes(base64.b64decode(b64))
    except Exception as e:
        print(f"::error::ANDROID_KEYSTORE_BASE64 解码失败：{e}")
        return 1
    # 密码含引号/反斜杠会拼坏 gradle 字符串：用随机十六进制密码即可（openssl rand -hex 16）
    if "'" in password or "\\" in password:
        print("::error::ANDROID_KEYSTORE_PASSWORD 含引号/反斜杠，无法安全注入 gradle，请换随机十六进制密码")
        return 1
    if not GRADLE.exists():
        print(f"::error::{GRADLE} 不存在（须在 flutter create 之后执行）")
        return 1
    src = GRADLE.read_text(encoding="utf-8")
    sign_block = f"""\
    signingConfigs {{
        duiduiRelease {{
            storeFile file('duidui-release.keystore')
            storePassword '{password}'
            keyAlias '{ALIAS}'
            keyPassword '{password}'
            storeType 'PKCS12'
        }}
    }}
"""
    if "duiduiRelease" in src:
        print("签名配置已存在，跳过注入")
        return 0
    if "duidui-release.keystore" not in src:
        # 注入独立的 signingConfigs 块（Groovy DSL 允许多次配置同一容器，会合并）
        m = re.search(r"(?m)^    buildTypes \{", src)
        if not m:
            print("::error::未找到 buildTypes 块，模板可能已变化")
            return 1
        src = src[: m.start()] + sign_block + src[m.start():]
    # buildTypes.release 的签名从 debug 换成 duiduiRelease（兼容两种写法）
    new, n = re.subn(
        r"signingConfig\s*=?\s*signingConfigs\.debug",
        "signingConfig signingConfigs.duiduiRelease",
        src,
    )
    if n == 0:
        print("::error::未找到 signingConfigs.debug 引用，模板可能已变化")
        return 1
    GRADLE.write_text(new, encoding="utf-8")
    print(f"已注入固定签名配置（替换 {n} 处 signingConfig 引用）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
