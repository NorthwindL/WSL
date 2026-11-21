# WSLg 中文、截图与双向文件剪贴板

在 Debian / Ubuntu WSLg 普通用户终端执行：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/NorthwindL/WSL/main/install.sh -o /tmp/wsl-ai-install.sh
bash /tmp/wsl-ai-install.sh
```

安装时按提示输入 Linux 用户的 sudo 密码。默认启用双向文件桥接，文字和截图使用 WSLg 原生剪贴板。默认不安装中文语言包、输入法或独立桌面，不修改应用的显示后端。安装后退出并重新打开目标应用。

## 默认行为

| 内容 | 实现方式 |
|---|---|
| 中文文字、多行、emoji | 使用 WSLg 原生通道，保留原生 xclip 的选择区和参数行为 |
| Windows 截图 | 使用 WSLg 原生图片通道；安装 wl-copy / wl-paste 便于操作 Wayland 剪贴板 |
| Windows → WSLg 文件 | 后台服务读取 Windows 磁盘文件列表，完成受限复制后向当前 X11 剪贴板发布 text/uri-list |
| WSLg → Windows 文件 | 后台服务读取 X11 文件 URI，通过 WSL 共享路径发布 Windows FileDrop；不复制文件内容到控制台 |
| 文件副本 | 保存至 ~/.cache/wsl-clipboard/files/copy-*，目录权限 0700，文件补充当前用户读写权限 |
| 容量与空间 | 单次总量最多 512 MiB、最多 10000 个文件及目录；预检并在复制中检查大小和剩余空间，保留至少 64 MiB |
| 自动清理 | 每小时删除创建超过 24 小时的托管副本；下次文件复制前也执行清理 |
| 旧版迁移 | 停用旧全量桥接和单向文件服务，恢复 /usr/local/bin/xclip 为原生 /usr/bin/xclip 的转发入口；备份已有配置 |

文件复制拒绝符号链接（含目录内部链接）、设备与其他特殊文件。文件全部复制成功后才发布路径，失败则移除本次副本并保留现有应用剪贴板。同名文件放在不同子目录；中文、空格、emoji 和换行文件名通过 JSON 或 NUL 协议传递。文件桥接不转换普通文本路径。

文件桥接覆盖 **WSLg X11 应用**，粘贴目标须支持文件 URI，例如文件管理器或支持附件粘贴的编辑器。原生 Wayland 应用是否接受跨系统文件取决于其自身及 WSLg 支持，当前文件桥接不覆盖其 Wayland 选择区。文字和截图的原生能力同样取决于目标应用支持的剪贴板格式，安装工具本身不保证所有应用的兼容性。

Windows 虚拟文件对象（如部分邮件附件）未实现 IStream 协议，目前支持磁盘文件与目录。反向粘贴时需保持 WSL 发行版运行、源文件可访问。暂存副本会在 24 小时后清理，长期使用的文件应及时另存。

## 常用命令

```bash
# 预览安装计划（不修改系统）
bash /tmp/wsl-ai-install.sh --dry-run

# 默认：双向文件桥接；文字与截图走 WSLg 原生通道
bash /tmp/wsl-ai-install.sh

# 同时安装中文字体、语言和 Fcitx5
bash /tmp/wsl-ai-install.sh --with-chinese

# 检查默认文件桥接
bash /tmp/wsl-ai-install.sh --check

# 故障排查时，显式关闭文件桥接，仅保留 WSLg 原生通道
bash /tmp/wsl-ai-install.sh --native

# 兼容部分普通 X11 应用：同时接管文字、图片和文件
bash /tmp/wsl-ai-install.sh --desktop-bridge

# 需要独立窗口时，显式安装并启动（X11）
bash /tmp/wsl-ai-install.sh --file-session
~/.local/bin/wsl-clipboard-app 程序名 [参数...]

# 为已安装的 OpenCode 配置独立窗口
bash /tmp/wsl-ai-install.sh --opencode-session

# 显式执行系统软件升级
bash /tmp/wsl-ai-install.sh --upgrade
```

`--with-files` 等同默认双向文件模式。`--files-out` 保留单向 Linux → Windows 文件模式。`--opencode-wayland` 是旧版独立窗口参数的兼容别名。增强模式的图片读取沿用 PNG 优先、Bitmap 转 PNG 的逻辑；普通文件模式不读取或重发布文字、图片。

`--file-session` 仅在显式选择时安装 Xephyr 和 Openbox，启动器要求前台应用实例。单实例程序应选择独立实例参数。默认模式直接打开普通 WSLg 应用。

## 安装依赖和重启

基础依赖为 xclip、wl-clipboard、python3、dbus-user-session、systemd、systemd-sysv、coreutils、util-linux、libc-bin 和 diffutils。默认双向文件桥接还需要 g++、pkg-config、qtbase5-dev 和 procps。安装器使用 `--no-install-recommends`，默认只更新 APT 索引并安装依赖。中文环境与系统升级须显式选择。

若 PID 1 不是 systemd，安装器会合并 /etc/wsl.conf 的 systemd 与互操作设置，保留其他键，以状态码 2 退出。保存工作后，在 Windows 终端运行 `wsl -t <发行版名>`，再运行 `wsl -d <发行版名>`，然后重新执行安装命令。systemd 用户总线必须可用。

已有被修改配置备份至 `~/.local/state/wsl-ai-setup/backups/时间-进程号/`。重复安装会按所选模式管理桥接服务。默认不改变已有语言配置；如旧版已安装中文环境，跳过中文安装不会卸载软件或删除其环境变量。

## 验证与排查

1. Windows 复制中文多行文字到 WSLg 应用，再反向复制核对。
2. 用 Win+Shift+S 截图，确认目标应用收到图片附件。
3. Windows 资源管理器复制中文文件、同名文件和目录，在 WSLg 文件管理器粘贴后打开核对。
4. 从 WSLg 文件管理器复制 Linux 文件到 Windows 资源管理器，粘贴并核对内容。
5. 测试超过 512 MiB、符号链接及磁盘空间不足的选区，确认拒绝且未发布不完整路径。

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
systemctl --user status wsl-clipboard-desktop.service --no-pager -l
journalctl --user -u wsl-clipboard-desktop.service -n 30 --no-pager
systemctl --user list-timers wsl-clipboard-cleanup.timer

# 立即清理过期副本
~/.local/lib/wsl-clipboard-session/stage-files --cleanup
```

遇到 Unit not found，确认当前主机、WSL 发行版和用户与安装时一致。服务需要 Windows PowerShell 与 WSL 互操作 socket。多个发行版使用各自的缓存和服务，Windows 剪贴板仍为共享资源。

## 开发验证

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
```

测试覆盖文件暂存边界、空间检查、权限、文件名、清理、安装计划和内嵌 Bash 语法。CI 另编译内嵌 Qt C++ 程序。Linux CI 无法替代 Windows / WSLg 上的双向实际粘贴验收。
