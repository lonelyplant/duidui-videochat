#!/usr/bin/env python3
"""为「无证书构建未签名 IPA」修补 iOS 工程（供 TrollStore 安装）。

要解决两类在 GitHub Actions 上无语证书构建 iOS 时最常见的问题：

1) Pod 目标仍要求签名
   `flutter build ios --no-codesign` 通过命令行把 CODE_SIGNING_ALLOWED=NO 传给
   Runner 主目标，但 CocoaPods 的各 framework 目标（声网 Agora、shared_preferences
   等）不受影响，仍会尝试 codesign 而失败。→ 在 Podfile 的 post_install 中把全部
   pod 目标的 codesigning 关掉。

2) Xcode 15/16 的脚本沙箱导致 Run Script 阶段失败
   新 Xcode 默认对 Run Script 启用沙箱，Flutter / Pods 的脚本阶段可能因
   “Sandbox: ... deny ...” 报 “Command PhaseScriptExecution failed”。
   → 在 Runner 工程里显式设置 ENABLE_USER_SCRIPT_SANDBOXING = NO。

脚本会打印修改结果，便于在 CI 日志里确认是否生效。
"""
import os
import re
import sys

PODFILE = os.path.join('ios', 'Podfile')
PBXPROJ = os.path.join('ios', 'Runner.xcodeproj', 'project.pbxproj')

# 注入到 Podfile 的 post_install 块顶部：关闭全部 pod 目标的签名
POD_TARGET_SETTINGS = (
    "  installer.pods_project.targets.each do |target|\n"
    "    target.build_configurations.each do |config|\n"
    "      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'\n"
    "      config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'\n"
    "      config.build_settings['CODE_SIGN_IDENTITY'] = ''\n"
    "      config.build_settings['EXPANDED_CODE_SIGN_IDENTITY'] = ''\n"
    "    end\n"
    "  end\n"
)


def patch_podfile() -> None:
    if not os.path.exists(PODFILE):
        print(f'::warning::未找到 {PODFILE}，跳过 Podfile 补丁')
        return
    with open(PODFILE, 'r', encoding='utf-8') as f:
        s = f.read()

    if 'CODE_SIGNING_ALLOWED' in s:
        print('Podfile 已包含 CODE_SIGNING_ALLOWED，跳过')
        return

    m = re.search(r'post_install do \|installer\|\n', s)
    if m:
        s = s[:m.end()] + POD_TARGET_SETTINGS + s[m.end():]
    else:
        s = s.rstrip() + "\n\npost_install do |installer|\n" + POD_TARGET_SETTINGS + "end\n"

    with open(PODFILE, 'w', encoding='utf-8') as f:
        f.write(s)
    idx = s.find('post_install')
    print('===== Podfile post_install（补丁后）=====')
    print(s[idx:idx + 700])
    print('===== /Podfile =====')


def patch_pbxproj_sandbox() -> None:
    if not os.path.exists(PBXPROJ):
        print(f'::warning::未找到 {PBXPROJ}，跳过沙箱设置')
        return
    with open(PBXPROJ, 'r', encoding='utf-8') as f:
        s = f.read()

    if 'ENABLE_USER_SCRIPT_SANDBOXING' in s:
        print('pbxproj 已包含 ENABLE_USER_SCRIPT_SANDBOXING，跳过')
        return

    needle = 'buildSettings = {\n'
    count = s.count(needle)
    s = s.replace(needle, needle + '\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;\n')
    with open(PBXPROJ, 'w', encoding='utf-8') as f:
        f.write(s)
    print(f'已在 {count} 处 buildSettings 注入 ENABLE_USER_SCRIPT_SANDBOXING = NO')


def main() -> int:
    patch_podfile()
    patch_pbxproj_sandbox()
    return 0


if __name__ == '__main__':
    sys.exit(main())
