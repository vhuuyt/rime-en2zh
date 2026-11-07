#!/usr/bin/env python3
"""给 ai_bridge.py 装/卸开机自启（跨平台，不用 PowerShell）。

    python scripts\\install_autostart.py            # 安装
    python scripts\\install_autostart.py --remove   # 卸载
    python scripts\\install_autostart.py --show     # 看现在装的是什么

各平台做的事：
    Windows : 在「启动」文件夹写一个 .vbs（wscript 静默拉起 pythonw，无窗口）
    macOS   : ~/Library/LaunchAgents/com.rime.en-ai.plist
    Linux   : ~/.config/autostart/rime-en-ai.desktop
"""
import argparse
import os
import sys

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai_bridge.py")


def pythonw():
    """优先 pythonw（不弹控制台），退而求其次用 python。"""
    exe = sys.executable
    for cand in (exe.replace("python.exe", "pythonw.exe"),
                 os.path.join(os.path.dirname(exe), "pythonw.exe")):
        if os.path.isfile(cand):
            return cand
    return exe


def windows_target():
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    return os.path.join(base, "Microsoft", "Windows", "Start Menu", "Programs",
                        "Startup", "rime-en-ai.vbs")


def macos_target():
    return os.path.expanduser("~/Library/LaunchAgents/com.rime.en-ai.plist")


def linux_target():
    return os.path.expanduser("~/.config/autostart/rime-en-ai.desktop")


def target():
    if os.name == "nt":
        return windows_target()
    if sys.platform == "darwin":
        return macos_target()
    return linux_target()


def content():
    pyw, script = pythonw(), SCRIPT
    if os.name == "nt":
        # wscript 隐藏窗口拉起 pythonw
        return ('Set sh = CreateObject("WScript.Shell")\r\n'
                f'sh.Run """{pyw}"" ""{script}""", 0, False\r\n')
    if sys.platform == "darwin":
        return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.rime.en-ai</string>
  <key>ProgramArguments</key>
  <array>
    <string>{pyw}</string>
    <string>{script}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
"""
    return f"""[Desktop Entry]
Type=Application
Name=Rime en-ai bridge
Exec={pyw} {script}
X-GNOME-Autostart-enabled=true
Terminal=false
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--show", action="store_true")
    args = ap.parse_args()

    path = target()
    if args.show:
        if os.path.isfile(path):
            print(f"已安装: {path}\n")
            print(open(path, encoding="utf-8", errors="replace").read())
        else:
            print(f"未安装（预期位置: {path}）")
        return 0

    if args.remove:
        if os.path.isfile(path):
            os.remove(path)
            print(f"已卸载: {path}")
        else:
            print(f"未安装: {path}")
        return 0

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(content())
    print(f"已安装: {path}")
    print(f"  拉起的命令: {pythonw()} {SCRIPT}")
    print("登录后自动生效；现在想立刻启动：")
    print(f'  "{pythonw()}" "{SCRIPT}"')
    return 0


if __name__ == "__main__":
    sys.exit(main())
