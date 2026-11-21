#!/usr/bin/env bash
# Debian/Ubuntu WSL setup. Run as the Linux desktop user.
set -Eeuo pipefail
umask 022

DRY_RUN=false
CHECK_ONLY=false
INSTALL_CHINESE=true
CLIPBOARD_MODE=files
UPGRADE=false
OPENCODE_SESSION=false
STEP=准备
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/wsl-ai-setup"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
TEMP_DIR=
BACKUP_DIR=

log() { printf '\n[%s] %s\n' "$STEP" "$*"; }
fail() { printf '\n安装未完成，%s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z $TEMP_DIR ]] || rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT
trap 'printf "\n安装在【%s】失败（第%s行）。修复报错后可重新运行。\n" "$STEP" "$LINENO" >&2' ERR

usage() {
    cat <<'HELP'
用法 bash install.sh [选项]
默认启用双向文件桥接；文字和截图保留 WSLg 原生通道，后台只桥接文件，默认安装中文环境和 Fcitx5，不安装独立桌面。
  --dry-run         显示安装计划，保持系统当前状态
  --check           检查依赖和后台服务状态
  --with-chinese    安装中文字体、语言和 Fcitx5 输入法（默认）
  --without-chinese 不安装中文字体、语言和 Fcitx5 输入法
  --native          仅原生通道，显式关闭文件桥接
  --desktop-bridge  可选：为普通 X11 窗口提供 Windows 剪贴板数据
  --file-session    安装双向文件、图片与文本的独立窗口启动器
  --with-files      双向文件桥接（默认）
  --files-out       仅启用 WSLg 到 Windows 文件桥接
  --upgrade         显式执行系统软件升级
  --opencode-session 为已安装的 OpenCode 配置独立剪贴板窗口
  --skip-upgrade    跳过系统软件升级
  -h, --help        显示帮助
请在目标 WSL 的普通用户终端运行，安装过程通过 sudo 请求管理员权限。
HELP
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --check) CHECK_ONLY=true ;;
            --with-chinese) INSTALL_CHINESE=true ;;
            --without-chinese) INSTALL_CHINESE=false ;;
            --native) CLIPBOARD_MODE=native ;;
            --desktop-bridge) CLIPBOARD_MODE=desktop ;;
            --file-session) CLIPBOARD_MODE=session ;;
            --with-files) CLIPBOARD_MODE=files ;;
            --files-out) CLIPBOARD_MODE=files-out ;;
            --upgrade) UPGRADE=true ;;
            --opencode-session|--opencode-wayland) OPENCODE_SESSION=true ;;
            --skip-upgrade) UPGRADE=false ;;
            -h|--help) usage; exit 0 ;;
            *) fail "未知参数 $1" ;;
        esac
        shift
    done
}

# Preserve other sections and keys when updating wsl.conf.
set_ini_value() {
    local section=$1 key=$2 value=$3 source=$4
    awk -v section="$section" -v key="$key" -v value="$value" '
        function finish_section() {
            if (inside && !written) { print key "=" value; written=1 }
        }
        /^[[:space:]]*\[/ {
            finish_section()
            name=$0
            sub(/^[[:space:]]*\[/, "", name)
            sub(/\].*$/, "", name)
            inside=(name == section)
            if (inside) found=1
        }
        {
            line=$0
            if (inside && line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                if (!written) print key "=" value
                written=1
            } else print
        }
        END {
            finish_section()
            if (!found) print "\n[" section "]\n" key "=" value
        }
    ' "$source"
}

backup() {
    local path=$1
    if [[ -e $path || -L $path ]]; then
        mkdir -p -- "$BACKUP_DIR$(dirname "$path")"
        if [[ -w $path && ! -L $path ]]; then
            cp -a -- "$path" "$BACKUP_DIR$path"
        else
            sudo cp -a -- "$path" "$BACKUP_DIR$path"
        fi
    fi
}

write_user_file() {
    local path=$1 mode=$2
    local staged
    staged=$(mktemp "$TEMP_DIR/user.XXXXXXXX")
    cat > "$staged"
    if [[ -f $path ]] && cmp -s -- "$path" "$staged"; then
        chmod "$mode" -- "$path"
        return
    fi
    backup "$path"
    mkdir -p -- "$(dirname "$path")"
    install -m "$mode" -- "$staged" "$path"
}

user_systemctl() {
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" systemctl --user "$@"
}

apt_run() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold "$@"
}

check_installation() {
    local failed=0
    if [[ $CLIPBOARD_MODE == desktop || $CLIPBOARD_MODE == files ]]; then
        [[ -x $HOME/.local/lib/wsl-clipboard-session/session &&
           -r $HOME/.local/lib/wsl-clipboard-session/backend.ps1 ]] || {
            printf '缺少普通 WSLg 剪贴板辅助程序。\n' >&2
            failed=1
        }
        if ! user_systemctl is-active --quiet wsl-clipboard-desktop.service; then
            printf '普通 WSLg 剪贴板服务未运行。\n' >&2
            failed=1
        fi
    fi
    if [[ $CLIPBOARD_MODE == session ]]; then
        [[ -x $HOME/.local/bin/wsl-clipboard-app &&
           -x $HOME/.local/lib/wsl-clipboard-session/session &&
           -r $HOME/.local/lib/wsl-clipboard-session/backend.ps1 ]] || {
            printf '缺少独立窗口启动器或剪贴板辅助程序。\n' >&2
            failed=1
        }
    fi
    for path in /usr/local/bin/xclip /usr/bin/wl-copy /usr/bin/wl-paste "$HOME/.local/bin/wsl-xclip" "$HOME/.local/lib/wsl-clipboard-session/stage-files"; do
        if [[ -x $path ]]; then printf '已安装 %s\n' "$path"; else printf '缺少 %s\n' "$path"; failed=1; fi
    done
    if ! user_systemctl is-active --quiet wsl-clipboard-cleanup.timer; then
        printf '文件副本清理定时器未运行。\n' >&2
        failed=1
    fi
    for service in xclip-files-bridge.service xclip-linux-files-bridge.service xclip-bridge.service; do
        if user_systemctl is-enabled "$service" >/dev/null 2>&1 ||
            user_systemctl is-active "$service" >/dev/null 2>&1; then
            user_systemctl status "$service" --no-pager -l || true
        fi
    done
    return "$failed"
}

preflight() {
    [[ $(id -u) -ne 0 ]] || fail '请用目标 Linux 普通用户运行，勿在命令前加 sudo。'
    [[ -f /etc/os-release ]] || fail '缺少发行版信息。'
    . /etc/os-release
    case "${ID:-}" in debian|ubuntu) ;; *) fail '支持 Debian 和 Ubuntu。' ;; esac
    [[ -n ${WSL_DISTRO_NAME:-} && -d /run/WSL ]] || fail '请在目标 WSL 的终端中运行。'
    [[ ${DISPLAY:-} =~ ^:[0-9]+(\.[0-9]+)?$ ]] || fail '请在 WSLg 图形终端运行，DISPLAY 应类似 :0。'
    [[ $WSL_DISTRO_NAME =~ ^[A-Za-z0-9._-]+$ ]] || fail '发行版名称包含暂未支持的字符。'
    [[ $CONFIG_DIR == "$HOME/.config" ]] || fail '当前版本要求 XDG_CONFIG_HOME 使用默认 ~/.config。'
    command -v sudo >/dev/null || fail '请先由管理员安装 sudo 并授予当前用户 sudo 权限。'
    sudo -v
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    exec 8> "$STATE_DIR/install.lock"
    flock -n 8 || fail '另一个安装进程正在运行。'
    BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    TEMP_DIR=$(mktemp -d /tmp/wsl-ai-setup.XXXXXXXX)
    chmod 755 "$TEMP_DIR"
}

install_packages() {
    STEP=系统组件
    local packages=(coreutils util-linux libc-bin diffutils xclip wl-clipboard python3 dbus-user-session
        systemd systemd-sysv)
    if [[ $INSTALL_CHINESE == true ]]; then
        packages+=(locales fonts-noto-cjk fonts-wqy-microhei fontconfig fcitx5
            fcitx5-chinese-addons fcitx5-config-qt fcitx5-frontend-gtk3 fcitx5-frontend-qt5)
    fi
    if [[ $CLIPBOARD_MODE == session || $CLIPBOARD_MODE == desktop || $CLIPBOARD_MODE == files ]]; then
        packages+=(g++ pkg-config qtbase5-dev procps)
    fi
    if [[ $CLIPBOARD_MODE == session ]]; then
        packages+=(xserver-xephyr openbox dbus-daemon xauth x11-utils)
    fi
    apt_run update
    if [[ $UPGRADE == true ]]; then apt_run upgrade -y; fi
    apt_run install -y --no-install-recommends "${packages[@]}"
}

configure_wsl() {
    STEP=WSL启动设置
    if sudo test -f /etc/wsl.conf; then
        # The redirect writes to the current user's staging directory.
        # shellcheck disable=SC2024
        sudo cat /etc/wsl.conf > "$TEMP_DIR/wsl.conf"
    else
        : > "$TEMP_DIR/wsl.conf"
    fi
    set_ini_value boot systemd true "$TEMP_DIR/wsl.conf" > "$TEMP_DIR/wsl.1"
    set_ini_value interop enabled true "$TEMP_DIR/wsl.1" > "$TEMP_DIR/wsl.2"
    set_ini_value interop appendWindowsPath true "$TEMP_DIR/wsl.2" > "$TEMP_DIR/wsl.3"
    if ! sudo cmp -s /etc/wsl.conf "$TEMP_DIR/wsl.3"; then
        backup /etc/wsl.conf
        sudo install -m 644 "$TEMP_DIR/wsl.3" /etc/wsl.conf
    fi
    if [[ $(ps -p 1 -o comm=) != systemd ]]; then
        log '已启用 systemd。请保存工作，重新启动此 WSL 发行版后，再运行相同安装命令。'
        exit 2
    fi
    [[ -S /run/user/$(id -u)/bus ]] || fail 'systemd 用户总线尚未就绪。请重新进入当前 WSL 用户后再次运行。'
}

configure_chinese() {
    STEP=中文和输入法
    backup /etc/locale.gen
    sudo sed -i -E 's/^[#[:space:]]*(zh_CN.UTF-8[[:space:]]+UTF-8).*$/\1/' /etc/locale.gen
    sudo locale-gen zh_CN.UTF-8
    backup /etc/default/locale
    sudo update-locale LANG=zh_CN.UTF-8
    fc-cache -f
    write_user_file "$CONFIG_DIR/wsl-ai-setup/environment.sh" 644 <<'ENVIRONMENT'
export LANG=zh_CN.UTF-8
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS='@im=fcitx'
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
ENVIRONMENT
    for rc in "$HOME/.profile" "$HOME/.bashrc"; do
        touch "$rc"
        backup "$rc"
        awk '
            /^# BEGIN wsl-ai-setup$/ { managed=1; next }
            /^# END wsl-ai-setup$/ { managed=0; next }
            managed { next }
            /^[[:space:]]*fcitx5[[:space:]]+--disable=wayland[[:space:]]+-d[[:space:]]+--replace([[:space:]].*)?$/ { next }
            /^[[:space:]]*eval \$\(dbus-launch --sh-syntax\)[[:space:]]*$/ { next }
            { print }
        ' "$rc" > "$TEMP_DIR/rc"
        cat >> "$TEMP_DIR/rc" <<'RC'
# BEGIN wsl-ai-setup
. "$HOME/.config/wsl-ai-setup/environment.sh"
# END wsl-ai-setup
RC
        cat "$TEMP_DIR/rc" > "$rc"
    done
    if [[ ! -e $CONFIG_DIR/fcitx5/profile ]]; then
        write_user_file "$CONFIG_DIR/fcitx5/profile" 600 <<'PROFILE'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin
[Groups/0/Items/0]
Name=keyboard-us
Layout=
[Groups/0/Items/1]
Name=pinyin
Layout=
[GroupOrder]
0=Default
PROFILE
    fi
}

install_clipboard() {
    STEP=剪贴板
    mkdir -p "$HOME/.local/lib/xclip-x11/usr/bin"
    write_user_file "$HOME/.local/lib/xclip-x11/usr/bin/xclip" 755 < /usr/bin/xclip
    cat > "$TEMP_DIR/xclip" <<'XCLIP_SOURCE'
#!/bin/bash
# WSL clipboard bridge. Payloads cross the console as ASCII base64.
set -euo pipefail
umask 077

die() { printf 'xclip: %s\n' "$*" >&2; exit 1; }

direction=in
watch_mode=false
watch_files_out=false
target=UTF8_STRING
selection=clipboard
files=()
while (($#)); do
    case "$1" in
        --watch-files-out) watch_mode=true; watch_files_out=true ;;
        -o|-out) direction=out ;;
        -i|-in) direction=in ;;
        -selection|-sel) shift; (($#)) || die 'missing selection'; selection=$1 ;;
        -target|-t) shift; (($#)) || die 'missing target'; target=$1 ;;
        -silent|-quiet|-verbose) ;;
        -loops|-l) shift; (($#)) || die 'missing loop count' ;;
        -h|-help|--help)
            printf 'Usage: xclip [-in|-out] [-selection clipboard] [-target TARGET] [FILE...]\n'
            printf 'Run xclip --watch-files-out to publish Linux file URIs to the Windows clipboard.\n'
            printf 'Targets: UTF8_STRING, STRING, TEXT, text/plain, text/plain;charset=utf-8, image/png, TARGETS, text/uri-list\n'
            exit 0 ;;
        -version|--version) printf 'xclip WSL bridge 2.1\n'; exit 0 ;;
        --) shift; files+=("$@"); break ;;
        -*) die "unsupported option: $1" ;;
        *) files+=("$1") ;;
    esac
    shift
done
case "$selection" in
    clipboard|clip|c|primary|p|secondary|s) ;;
    *) die "unsupported selection: $selection" ;;
esac
# Windows has one shared clipboard, so X11 selection names map to it.
case "$target" in
    UTF8_STRING|STRING|TEXT|text/plain|text/plain\;charset=utf-8) kind=text ;;
    image/png) kind=image ;;
    TARGETS) kind=targets ;;
    text/uri-list) kind=uris ;;
    *) die "unsupported target: $target" ;;
esac
if [[ $direction == out && ${#files[@]} != 0 ]]; then
    die 'output mode does not accept input files'
fi
if [[ $direction == in && $kind != text && $kind != image ]]; then
    die 'this target is read-only'
fi

work=$(mktemp -d /tmp/xclip-request.XXXXXXXX)
copy_root=
producer=
keep_copy=false
cleanup_copy() {
    if [[ -n $copy_root && $keep_copy == false ]]; then
        chmod -R u+rwX -- "$copy_root" 2>/dev/null || true
        rm -rf -- "$copy_root"
    fi
}
cleanup() {
    if [[ -n $producer ]]; then kill "$producer" 2>/dev/null || true; wait "$producer" 2>/dev/null || true; fi
    rm -rf -- "$work"
    cleanup_copy
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

copy_files() {
    : > "$work/paths" || die 'cannot create copy manifest'
    sources=()
    while IFS= read -r path_b64 <&3; do
        [[ -n $path_b64 ]] || continue
        win_path=$(printf '%s' "$path_b64" | base64 -d) || die 'invalid file path payload'
        source_path=$(wslpath -u "$win_path") || die 'path conversion failed'
        sources+=("$source_path")
    done
    "$HOME/.local/lib/wsl-clipboard-session/stage-files" --null "${sources[@]}" > "$work/staged" || die 'file staging failed'
    index=0
    while IFS= read -r -d '' destination; do
        index=$((index + 1))
        if [[ -z $copy_root ]]; then copy_root=$(dirname -- "$(dirname -- "$destination")"); fi
        if [[ $kind == uris ]]; then
            # URI bytes are percent-encoded, including spaces and UTF-8.
            uri=
            LC_ALL=C
            for ((i=0; i<${#destination}; i++)); do
                char=${destination:i:1}
                case "$char" in
                    [a-zA-Z0-9/._~-]) uri+=$char ;;
                    *) printf -v hex '%%%02X' "'$char"; uri+=$hex ;;
                esac
            done
            printf 'file://%s\r\n' "$uri" >> "$work/paths" || die 'cannot write copy manifest'
        else
            printf '%s\n' "$destination" >> "$work/paths" || die 'cannot write copy manifest'
        fi
    done < "$work/staged"
    ((index > 0)) || die 'empty file list'
    # Publish paths only after every copy has completed successfully.
    cat -- "$work/paths" || die 'cannot output copy manifest'
    keep_copy=true
}

if [[ $watch_mode == true ]]; then
    native="$HOME/.local/lib/xclip-x11/usr/bin/xclip"
    [[ -x $native ]] || die 'native X11 xclip is missing from ~/.local/lib/xclip-x11'
    lock_name=files-out
    lock_dir="${XDG_RUNTIME_DIR:-$HOME/.cache}/xclip-bridge-$lock_name"
    mkdir -p -m 700 -- "$lock_dir"
    exec 9> "$lock_dir/lock"
    flock -n 9 || die 'a clipboard bridge is already running'
    if [[ $watch_files_out != true ]]; then die 'unsupported watch mode'; fi
    # Resolve and publish only Linux file URIs; never sample the Windows clipboard.
    powershell=$(command -v powershell.exe || true)
    if [[ -z $powershell ]]; then powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; fi
    [[ -x $powershell ]] || die 'Windows PowerShell executable is unavailable'
    watch_script=$(cat <<'WATCH_POWERSHELL'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$paths = New-Object System.Collections.Specialized.StringCollection
while (($line = [Console]::ReadLine()) -ne $null) {
    if ($line.Length -gt 0) {
        [void]$paths.Add($utf8.GetString([Convert]::FromBase64String($line)))
    }
}
if ($paths.Count -eq 0) { throw 'empty file list' }
for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try { [System.Windows.Forms.Clipboard]::SetFileDropList($paths); exit 0 }
    catch [System.Runtime.InteropServices.ExternalException] {
        if ($attempt -eq 4) { throw }
        Start-Sleep -Milliseconds 60
    }
}
WATCH_POWERSHELL
    )
    encoded=$(printf '%s' "$watch_script" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0)
    last_uri_fingerprint=
    while true; do
        if ! "$native" -selection clipboard -target text/uri-list -o > "$work/uris" 2>/dev/null; then
            last_uri_fingerprint=
            sleep 0.25
            continue
        fi
        tr -d '\r' < "$work/uris" > "$work/uris.normalized"
        mapfile -t uris < <(sed '/^[[:space:]]*$/d' "$work/uris.normalized")
        ((${#uris[@]})) || { sleep 0.25; continue; }
        uri_fingerprint=$(sha256sum "$work/uris.normalized")
        [[ $uri_fingerprint == "$last_uri_fingerprint" ]] && { sleep 0.25; continue; }
        : > "$work/windows-paths.b64"
        valid_count=0
        for uri in "${uris[@]}"; do
            [[ $uri == file:///* ]] || { valid_count=0; break; }
            linux_path=${uri#file://}
            decoded_path=
            LC_ALL=C
            for ((i=0; i<${#linux_path}; i++)); do
                char=${linux_path:i:1}
                if [[ $char == % && ${#linux_path} -ge $((i + 3)) ]]; then
                    hex=${linux_path:i+1:2}
                    [[ $hex =~ ^[0-9A-Fa-f]{2}$ ]] || { decoded_path+=$char; continue; }
                    printf -v byte '\\x%s' "$hex"
                    printf -v byte '%b' "$byte"
                    decoded_path+=$byte
                    i=$((i + 2))
                else
                    decoded_path+=$char
                fi
            done
            [[ $decoded_path == /tmp/chatgpt-clipboard.* || $decoded_path == "$HOME/.cache/wsl-clipboard/files/"* ]] && { valid_count=0; break; }
            [[ -f $decoded_path || -d $decoded_path ]] || { valid_count=0; break; }
            windows_path=$(wslpath -w -- "$decoded_path") || { valid_count=0; break; }
            printf '%s' "$windows_path" | base64 -w 0 >> "$work/windows-paths.b64"
            printf '\n' >> "$work/windows-paths.b64"
            valid_count=$((valid_count + 1))
        done
        if ((valid_count > 0)); then
            timeout 20s "$powershell" -NoLogo -NoProfile -NonInteractive -STA \
                -EncodedCommand "$encoded" < "$work/windows-paths.b64" ||
                printf 'xclip bridge: Linux file publish failed; waiting for next clipboard change\n' >&2
        fi
        last_uri_fingerprint=$uri_fingerprint
        sleep 0.25
    done
fi

# Services may have a minimal PATH without WSL interop directories.
powershell=$(command -v powershell.exe || true)
if [[ -z $powershell ]]; then powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; fi
[[ -x $powershell ]] || die 'Windows PowerShell executable is unavailable'

ps_script=$(cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
function Emit([string]$type, [byte[]]$bytes) {
    [Console]::WriteLine($type)
    [Console]::WriteLine([Convert]::ToBase64String($bytes))
}
try {
    if ($operation -eq 'in') {
        $bytes = [Convert]::FromBase64String([Console]::In.ReadToEnd())
        if ($kind -eq 'image') {
            $stream = New-Object System.IO.MemoryStream(,$bytes)
            try {
                $image = [System.Drawing.Image]::FromStream($stream)
                try { [System.Windows.Forms.Clipboard]::SetImage($image) }
                finally { $image.Dispose() }
            } finally { $stream.Dispose() }
        } else {
            $text = $utf8.GetString($bytes).Replace("`r`n", "`n").Replace("`r", "`n")
            if ($text.Length -eq 0) { [System.Windows.Forms.Clipboard]::Clear() }
            else { [System.Windows.Forms.Clipboard]::SetText($text) }
        }
        exit 0
    }
    $data = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try { $data = [System.Windows.Forms.Clipboard]::GetDataObject(); break }
        catch [System.Runtime.InteropServices.ExternalException] {
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds 60
        }
    }
    $hasFiles = $null -ne $data -and $data.GetDataPresent('FileDrop')
    $hasImage = $null -ne $data -and $data.GetDataPresent('Bitmap')
    $hasText = $null -ne $data -and $data.GetDataPresent('UnicodeText')
    $pngFile = $null
    if ($hasFiles) {
        $paths = @($data.GetData('FileDrop'))
        if ($paths.Count -eq 1 -and [System.IO.Path]::GetExtension($paths[0]) -ieq '.png') {
            $pngFile = [string]$paths[0]
        }
    }
    if ($kind -eq 'targets') {
        $targets = @('TARGETS')
        if ($hasFiles -or $hasText) {
            $targets += @('UTF8_STRING', 'STRING', 'TEXT', 'text/plain', 'text/plain;charset=utf-8')
        }
        if ($hasFiles) { $targets += 'text/uri-list' }
        if ($hasImage -or $null -ne $pngFile) { $targets += 'image/png' }
        Emit 'DATA' ($utf8.GetBytes(($targets -join "`n") + "`n"))
    } elseif ($kind -eq 'image') {
        if ($hasImage) { $image = $data.GetData('Bitmap') }
        elseif ($null -ne $pngFile) { $image = [System.Drawing.Image]::FromFile($pngFile) }
        else { throw 'Clipboard has no bitmap image.' }
        $stream = New-Object System.IO.MemoryStream
        try {
            $image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            Emit 'DATA' ($stream.ToArray())
        } finally { $stream.Dispose(); $image.Dispose() }
    } elseif ($hasFiles) {
        [Console]::WriteLine('FILES')
        foreach ($path in $data.GetData('FileDrop')) {
            [Console]::WriteLine([Convert]::ToBase64String($utf8.GetBytes([string]$path)))
        }
    } elseif ($kind -eq 'uris') {
        throw 'Clipboard has no file list.'
    } elseif ($hasText) {
        $text = [string]$data.GetData('UnicodeText')
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        Emit 'DATA' ($utf8.GetBytes($text))
    } else {
        throw 'Clipboard has no text or files for this target.'
    }
} catch {
    [Console]::Error.WriteLine('xclip clipboard bridge: ' + $_.Exception.Message)
    exit 1
}
POWERSHELL
)
# Only fixed enum values are inserted into the PowerShell source.
encoded=$(printf "\$operation = '%s'\n\$kind = '%s'\n%s\n" "$direction" "$kind" "$ps_script" |
    iconv -f UTF-8 -t UTF-16LE | base64 -w 0)
if [[ $direction == in ]]; then
    if ((${#files[@]})); then cat -- "${files[@]}" > "$work/input"; else cat > "$work/input"; fi
    base64 -w 0 "$work/input" > "$work/input.b64"
    timeout 20s "$powershell" -NoLogo -NoProfile -NonInteractive -STA -EncodedCommand "$encoded" < "$work/input.b64"
    exit 0
fi
timeout 20s "$powershell" -NoLogo -NoProfile -NonInteractive -STA -EncodedCommand "$encoded" > "$work/response" < /dev/null ||
    die 'clipboard read failed'
# Only the ASCII transport is normalized. Decoded image bytes stay untouched.
tr -d '\r' < "$work/response" > "$work/protocol"
exec 3< "$work/protocol"
IFS= read -r response_kind <&3 || die 'empty clipboard bridge response'
case "$response_kind" in
    DATA)
        base64 -d <&3 > "$work/output" || die 'invalid clipboard payload'
        cat -- "$work/output"
        ;;
    FILES)
        copy_files
        ;;
    *) die 'unknown clipboard bridge response' ;;
esac
XCLIP_SOURCE
    bash -n "$TEMP_DIR/xclip"
    write_user_file "$HOME/.local/bin/wsl-xclip" 755 < "$TEMP_DIR/xclip"
    # Preserve the native X11 selection protocol and options for existing callers.
    printf '#!/bin/sh\nexec /usr/bin/xclip "$@"\n' > "$TEMP_DIR/native-xclip"
    if ! cmp -s /usr/local/bin/xclip "$TEMP_DIR/native-xclip"; then
        backup /usr/local/bin/xclip
        sudo install -m 755 "$TEMP_DIR/native-xclip" /usr/local/bin/.xclip-wsl-ai-setup.$$
        sudo mv -f /usr/local/bin/.xclip-wsl-ai-setup.$$ /usr/local/bin/xclip
    fi
}

install_file_staging() {
    write_user_file "$HOME/.local/lib/wsl-clipboard-session/stage-files" 755 <<'STAGE_FILES'
#!/usr/bin/python3
"""Bounded private file copies shared by the shell and Qt clipboard bridges."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import sys
import tempfile
import time

MAX_BYTES = 512 * 1024 * 1024
MAX_ENTRIES = 10000
RESERVE = 64 * 1024 * 1024
TTL = 24 * 3600
ROOT = Path.home() / '.cache/wsl-clipboard/files'


def cleanup(root):
    for item in root.glob('copy-*'):
        info = item.lstat()
        if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and time.time() - info.st_mtime > TTL:
            shutil.rmtree(item)


def stage(paths, root):
    if not paths:
        raise ValueError('empty file list')
    plan, total = [], 0

    def inspect(source, relative):
        nonlocal total
        info = source.lstat()
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise ValueError('symbolic links and special files are unsupported: ' + str(source))
        if len(plan) >= MAX_ENTRIES:
            raise ValueError('file selection exceeds 10000 entries')
        total += info.st_size if stat.S_ISREG(info.st_mode) else 0
        if total > MAX_BYTES:
            raise ValueError('file selection exceeds 512 MiB')
        plan.append((source, relative, info))
        if stat.S_ISDIR(info.st_mode):
            for child in source.iterdir():
                inspect(child, relative / child.name)

    names = []
    for index, value in enumerate(paths, 1):
        source = Path(os.path.abspath(value))
        if source == Path(source.anchor) or source == root or root in source.parents or source in root.parents:
            raise ValueError('cannot stage filesystem roots or clipboard cache')
        relative = Path(str(index)) / source.name
        inspect(source, relative)
        names.append(relative)
    if shutil.disk_usage(root).free < total + RESERVE:
        raise ValueError('insufficient disk space (64 MiB reserve required)')
    target = Path(tempfile.mkdtemp(prefix='copy-', dir=root))
    copied = 0
    try:
        for source, relative, info in plan:
            dest = target / relative
            dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if stat.S_ISDIR(info.st_mode):
                dest.mkdir(mode=0o700)
                continue
            fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as src:
                current = os.fstat(src.fileno())
                if not stat.S_ISREG(current.st_mode) or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                    raise ValueError('source changed during copy')
                with dest.open('xb') as out:
                    os.chmod(dest, 0o600 | (info.st_mode & 0o100))
                    while True:
                        chunk = src.read(1024 * 1024)
                        if not chunk:
                            break
                        copied += len(chunk)
                        if copied > MAX_BYTES or shutil.disk_usage(root).free < len(chunk) + RESERVE:
                            raise ValueError('copy exceeds size or available space limit')
                        out.write(chunk)
        os.utime(target, None)
        return [str(target / name) for name in names]
    except BaseException:
        shutil.rmtree(target)
        raise


def main():
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if ROOT.is_symlink() or ROOT.stat().st_uid != os.getuid():
        raise ValueError('clipboard cache must be owned by the current user')
    ROOT.chmod(0o700)
    with (ROOT / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cleanup(ROOT)
        args = sys.argv[1:]
        if args == ['--cleanup']:
            return
        null = args[:1] == ['--null']
        if null:
            args = args[1:]
        result = stage(args, ROOT)
        if null:
            sys.stdout.buffer.write(b'\0'.join(os.fsencode(p) for p in result) + b'\0')
        else:
            print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RecursionError) as error:
        print('file staging: ' + str(error), file=sys.stderr)
        sys.exit(1)
STAGE_FILES
}

install_file_session() {
    local lib="$HOME/.local/lib/wsl-clipboard-session"
    cat > "$TEMP_DIR/session.cpp" <<'SESSION_CPP'
#include <QtGui>
#include <memory>

static QString mapPath(QString flag, QString path) {
    QProcess proc;
    proc.start("wslpath", {flag, "--", path});
    if (!proc.waitForFinished() || proc.exitCode()) return {};
    QByteArray bytes = proc.readAllStandardOutput();
    if (bytes.endsWith('\n')) bytes.chop(1);
    return QString::fromUtf8(bytes);
}

static QByteArray offer(const QMimeData *data, QByteArray seq, bool filesOnly) {
    if (!data) return {};
    // Do not ask native clipboard owners to render text/image data while
    // looking for files. This avoids unnecessary Windows/RDP data requests.
    if (filesOnly && !data->hasFormat("text/uri-list") &&
        !data->hasFormat("x-special/gnome-copied-files")) return {};
    QList<QUrl> urls = data->urls();
    if (urls.isEmpty() && data->hasFormat("x-special/gnome-copied-files")) {
        auto lines = data->data("x-special/gnome-copied-files").split('\n');
        const auto action = lines.takeFirst().trimmed();
        if (action != "copy" && action != "cut") return {};
        for (const auto &line : lines)
            if (!line.trimmed().isEmpty()) urls << QUrl::fromEncoded(line.trimmed(), QUrl::StrictMode);
    }
    if (!urls.isEmpty()) {
        QByteArray result = "FILES " + seq;
        for (const auto &url : urls) {
            if (!url.isLocalFile() || !QFileInfo::exists(url.toLocalFile())) return {};
            if (url.toLocalFile().startsWith(QDir::homePath() + "/.cache/wsl-clipboard/files/")) return {};
            QString path = mapPath("-w", url.toLocalFile());
            if (path.isEmpty()) return {};
            result += " " + path.toUtf8().toBase64();
        }
        return result;
    }
    if (filesOnly) return {};
    if (data->hasImage()) {
        QBuffer png;
        png.open(QIODevice::WriteOnly);
        if (!qvariant_cast<QImage>(data->imageData()).save(&png, "PNG")) return {};
        return "IMAGE " + seq + " " + png.data().toBase64();
    }
    if (data->hasText()) return "TEXT " + seq + " " + data->text().toUtf8().toBase64();
    return {};
}

struct StagedFiles {
    QString root;
    bool keep = false;
    ~StagedFiles() { if (!keep && !root.isEmpty()) QDir(root).removeRecursively(); }
};

static bool stageFiles(QMimeData &data, StagedFiles &staging, const QList<QByteArray> &paths, bool pathText) {
    QList<QUrl> urls;
    QStringList names, sources;
    for (const auto &encoded : paths) {
        QString path = mapPath("-u", QString::fromUtf8(QByteArray::fromBase64(encoded)));
        if (path.isEmpty()) return false;
        sources << path;
    }
    QProcess stage;
    stage.start(QDir::homePath() + "/.local/lib/wsl-clipboard-session/stage-files", sources);
    if (!stage.waitForStarted()) return false;
    QElapsedTimer deadline;
    deadline.start();
    while (stage.state() != QProcess::NotRunning && deadline.elapsed() < 120000) {
        stage.waitForFinished(20);
        QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);
    }
    if (stage.state() != QProcess::NotRunning || stage.exitStatus() != QProcess::NormalExit || stage.exitCode() != 0) {
        stage.terminate();
        if (!stage.waitForFinished(3000)) { stage.kill(); stage.waitForFinished(); }
        qWarning().noquote() << stage.readAllStandardError();
        return false;
    }
    const auto result = QJsonDocument::fromJson(stage.readAllStandardOutput());
    if (!result.isArray()) return false;
    for (const auto &entry : result.array()) {
        if (!entry.isString()) return false;
        names << entry.toString();
        urls << QUrl::fromLocalFile(names.last());
    }
    if (!names.isEmpty()) staging.root = QFileInfo(QFileInfo(names.first()).path()).path();
    data.setUrls(urls);
    // Advertising file paths as plain text makes WSLg mirror them back into
    // Windows, replacing the original clipboard formats. Only private sessions
    // may expose that convenience text target.
    if (pathText) data.setText(names.join('\n'));
    QByteArray gnomeFiles = "copy";
    for (const auto &url : urls) gnomeFiles += "\n" + url.toEncoded();
    data.setData("x-special/gnome-copied-files", gnomeFiles);
    return !urls.isEmpty();
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    if (argc != 3 && argc != 4) return 2;
    const bool filesOnly = argc == 4 && QByteArray(argv[3]) == "--files-only";
    const bool textFiles = argc == 4 && QByteArray(argv[3]) == "--text-files";
    const bool filesBridge = filesOnly || textFiles;
    const bool desktop = filesBridge || (argc == 4 && QByteArray(argv[3]) == "--desktop");
    if (argc == 4 && !desktop) return 2;
    QFile script(argv[2]);
    if (!script.open(QIODevice::ReadOnly)) return 1;
    QString src = QString::fromUtf8(script.readAll());
    if (desktop) {
        QByteArray identity = qgetenv("WSL_DISTRO_NAME") + '\n' + qgetenv("DISPLAY");
        QByteArray key = QCryptographicHash::hash(identity, QCryptographicHash::Sha256).toHex();
        src.prepend("$nativeDesktop = $true\n$desktopIdentity = '" + QString::fromLatin1(key) + "'\n");
    }
    if (filesOnly) src.prepend("$filesOnly = $true\n");
    if (textFiles) src.prepend("$textFiles = $true\n");
    QByteArray encoded(reinterpret_cast<const char *>(src.utf16()), src.size()*2);
    QProcess host;
    host.setProcessChannelMode(QProcess::ForwardedErrorChannel);
    host.start(argv[1], {"-NoProfile", "-NonInteractive", "-STA", "-EncodedCommand", encoded.toBase64()});
    if (!host.waitForStarted()) return 1;
    auto exchange = [&](QByteArray request) -> QList<QByteArray> {
        if (host.write(request + '\n') < 0) {
            qCritical("Windows clipboard helper stopped");
            app.exit(1);
            return {"ERROR"};
        }
        QElapsedTimer deadline;
        deadline.start();
        while (!host.canReadLine()) {
            host.waitForReadyRead(20);
            app.processEvents(QEventLoop::ExcludeUserInputEvents);
            if (host.state() == QProcess::NotRunning || deadline.elapsed() >= 30000) {
                qCritical("Windows clipboard helper did not respond");
                app.exit(1);
                return {"ERROR"};
            }
        }
        return host.readLine().trimmed().split(' ');
    };
    auto clipboard = app.clipboard();
    QByteArray seq = "-1";
    bool dirty = false, importing = false, busy = false;
    quint64 generation = 0;
    QObject::connect(clipboard, &QClipboard::dataChanged, [&] {
        if ((!desktop || filesBridge) && !importing && !clipboard->ownsClipboard()) {
            ++generation;
            dirty = true;
        }
    });
    QTimer timer;
    QObject::connect(&timer, &QTimer::timeout, [&] {
        if (busy) return;
        QScopedValueRollback<bool> processing(busy, true);
        bool retryExport = false;
        if ((!desktop || filesBridge) && dirty && seq != "-1") {
            dirty = false;
            const auto offeredGeneration = generation;
            QByteArray request = offer(clipboard->mimeData(), seq, filesBridge);
            app.processEvents(QEventLoop::ExcludeUserInputEvents);
            if (generation != offeredGeneration) return;
            if (!request.isEmpty() && (!filesBridge || request.startsWith("FILES "))) {
                auto reply = exchange(request);
                if (reply.first() == "OK") { seq = reply.value(1); return; }
                if (reply.first() == "ERROR") {
                    qWarning("File export failed; waiting for a new local copy instead of repeatedly writing Windows clipboard");
                    return;
                }
                // WSLg may have mirrored this selection while we prepared the
                // file offer. Refresh its version before retrying the export.
                if (reply.first() == "CHANGED") { retryExport = true; dirty = true; }
            }
        }
        auto frame = exchange("READ " + seq);
        auto type = frame.first(), version = frame.value(1);
        if (type == "SAME") { seq = version; return; }
        if (type == "ERROR" || type == "CHANGED") return;
        // A new external Windows selection wins over an outdated local offer.
        if (retryExport) dirty = false;
        if ((filesOnly && type != "FILES") ||
            (textFiles && type != "TEXT" && type != "FILES")) { seq = version; return; }
        auto data = std::make_unique<QMimeData>();
        StagedFiles staging;
        if (type == "FILES") {
            if (!stageFiles(*data, staging, frame.mid(2), !desktop)) {
                qWarning("Could not stage the complete file selection");
                data = std::make_unique<QMimeData>();
                seq = version;
                return;
            }
        } else if (type == "TEXT") {
            QString text = QString::fromUtf8(QByteArray::fromBase64(frame.value(2)));
            data->setText(text.replace("\r\n", "\n").replace('\r', '\n'));
        } else if (type == "IMAGE") {
            auto image = QImage::fromData(QByteArray::fromBase64(frame.value(2)), "PNG");
            if (!image.isNull()) data->setImageData(image);
        } else if (type != "EMPTY") return;
        if (exchange("CHECK " + version).first() != "CURRENT") return;
        app.processEvents(QEventLoop::ExcludeUserInputEvents);
        if (dirty && seq != "-1") return;
        staging.keep = true;
        importing = true;
        clipboard->setMimeData(data.release());
        importing = false;
        dirty = false;
        seq = version;
    });
    timer.start(filesOnly ? 500 : 250);
    return app.exec();
}
SESSION_CPP
    g++ -std=c++17 -O2 -fPIC "$TEMP_DIR/session.cpp" -o "$TEMP_DIR/session" $(pkg-config --cflags --libs Qt5Gui)
    write_user_file "$lib/session" 755 < "$TEMP_DIR/session"
    write_user_file "$lib/backend.ps1" 600 <<'SESSION_PS'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClipVersion {
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    public static uint OwnerProcessId() {
        uint id;
        GetWindowThreadProcessId(GetClipboardOwner(), out id);
        return id;
    }
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr window);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr memory);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr size);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr memory);
    public static string Publish(IntPtr window, uint expected, uint[] formats, byte[][] data) {
        IntPtr[] handles = new IntPtr[data.Length];
        bool opened = false;
        try {
            for (int i = 0; i < data.Length; i++) {
                handles[i] = GlobalAlloc(2, new UIntPtr((uint)data[i].Length));
                IntPtr ptr = GlobalLock(handles[i]);
                if (ptr == IntPtr.Zero) return "ERROR";
                try { Marshal.Copy(data[i], 0, ptr, data[i].Length); }
                finally { GlobalUnlock(handles[i]); }
            }
            opened = OpenClipboard(window);
            if (!opened) return "ERROR";
            if (GetClipboardSequenceNumber() != expected) return "CHANGED";
            if (!EmptyClipboard()) return "ERROR";
            for (int i = 0; i < formats.Length; i++) {
                if (SetClipboardData(formats[i], handles[i]) == IntPtr.Zero) return "ERROR";
                handles[i] = IntPtr.Zero;
            }
            return "OK " + GetClipboardSequenceNumber();
        } finally {
            if (opened) CloseClipboard();
            foreach (IntPtr h in handles) if (h != IntPtr.Zero) GlobalFree(h);
        }
    }
}
'@
# A regular Remote Desktop client can also own incoming clipboard data.
# Only the client explicitly launched with /wslg is a WSLg echo.
$script:wslgOwnerKey = ''
$script:wslgOwnerResult = $false
function Test-WslgCommandLine([string]$commandLine) {
    return $commandLine -match '(?i)(?:^|\s)/wslg(?:\s|$)'
}
function Test-WslgClipboardOwner {
    try {
        $ownerId = [ClipVersion]::OwnerProcessId()
        if (!$ownerId) { return $false }
        $process = [Diagnostics.Process]::GetProcessById([int]$ownerId)
        try {
            if ($process.ProcessName -notin @('msrdc', 'mstsc')) { return $false }
            $key = [string]$ownerId + ':' + [string]$process.StartTime.Ticks
        } finally { $process.Dispose() }
        if ($key -eq $script:wslgOwnerKey) { return $script:wslgOwnerResult }
        $details = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId" -ErrorAction Stop
        if (!$details -or !$details.CommandLine) { return $false }
        $result = Test-WslgCommandLine $details.CommandLine
        $script:wslgOwnerKey = $key
        $script:wslgOwnerResult = $result
        return $result
    } catch {
        # An unavailable process identity must not discard a remote clipboard.
        return $false
    }
}
$window = New-Object Windows.Forms.Control
$mutexName = 'Local\NorthwindWSLClipboardSession'
if ($nativeDesktop) { $mutexName = 'Local\NorthwindWSLClipboardDesktop.' + $desktopIdentity }
$mutex = [Threading.Mutex]::new($false, $mutexName)
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (!$owned) {
    if ($nativeDesktop) { throw 'A clipboard provider for this WSL distribution and display is already running' }
    throw 'Another WSL file session is running'
}
$bridgeMarker = [ClipVersion]::RegisterClipboardFormat('Northwind.WSL.FileClipboard.v1')
if (!$bridgeMarker) { throw 'Unable to register clipboard origin marker' }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
function Encode([string]$value) { [Convert]::ToBase64String($utf8.GetBytes($value)) }
function Decode([string]$value) { $utf8.GetString([Convert]::FromBase64String($value)) }
function Exchange([string]$request) {
    $parts = $request.Split(' ')
    $sequence = [ClipVersion]::GetClipboardSequenceNumber()
    if ($parts[0] -eq "CHECK") { if ($parts[1] -eq [string]$sequence) { return "CURRENT" }; return "CHANGED" }
    if ($parts[0] -eq 'READ') {
        if ($parts[1] -eq [string]$sequence) { return "SAME $sequence" }
        # Read format metadata before touching OLE clipboard data. Ordinary
        # Windows text, rich text and images must never be opened or imported
        # by the default file bridge.
        if ($filesOnly -and ![ClipVersion]::IsClipboardFormatAvailable(15)) { return "EMPTY $sequence" }
        if ([ClipVersion]::IsClipboardFormatAvailable($bridgeMarker)) { return "SAME $sequence" }
        # WSLg republishes Linux selections through its RDP client. Keep that
        # local selection instead of importing the same content again.
        if ($nativeDesktop -and (Test-WslgClipboardOwner)) { return "SAME $sequence" }
        $data = [Windows.Forms.Clipboard]::GetDataObject()
        $reply = "EMPTY $sequence"
        if ($data -and $data.GetDataPresent('FileDrop')) {
            $paths = @(foreach ($path in $data.GetData('FileDrop')) { Encode $path })
            $reply = "FILES $sequence " + ($paths -join ' ')
        } elseif ($textFiles -and $data -and $data.GetDataPresent('UnicodeText')) {
            $reply = "TEXT $sequence " + (Encode ([string]$data.GetData('UnicodeText')))
        } elseif ($filesOnly -or $textFiles) {
            $reply = "EMPTY $sequence"
        } elseif ($data -and $data.GetDataPresent('PNG', $false)) {
            $stream = $data.GetData('PNG', $false)
            $reply = "IMAGE $sequence " + [Convert]::ToBase64String($stream.ToArray())
        } elseif ($data -and $data.GetDataPresent('Bitmap')) {
            $image = $data.GetData('Bitmap')
            $stream = New-Object IO.MemoryStream
            try {
                $image.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
                $reply = "IMAGE $sequence " + [Convert]::ToBase64String($stream.ToArray())
            } finally { $stream.Dispose(); $image.Dispose() }
        } elseif ($data -and $data.GetDataPresent('UnicodeText')) {
            $reply = "TEXT $sequence " + (Encode ([string]$data.GetData('UnicodeText')))
        }
        if ([ClipVersion]::GetClipboardSequenceNumber() -ne $sequence) { return 'CHANGED' }
        return $reply
    }
    if ($filesOnly -and $parts[0] -ne 'FILES') { return 'ERROR' }
    if ($parts[1] -ne [string]$sequence) { return 'CHANGED' }
    $formats = [Collections.Generic.List[uint32]]::new()
    $payloads = [Collections.Generic.List[byte[]]]::new()
    switch ($parts[0]) {
        FILES {
            $paths = New-Object Collections.Specialized.StringCollection
            for ($i=2; $i -lt $parts.Length; $i++) { [void]$paths.Add((Decode $parts[$i])) }
            # DROPFILES followed by double-NUL-terminated UTF-16 paths.
            $header = New-Object byte[] 20
            $header[0] = 20
            $header[16] = 1
            $payloads.Add([byte[]]($header + [Text.Encoding]::Unicode.GetBytes(($paths -join [char]0) + [char]0 + [char]0)))
            $formats.Add(15)
            $formats.Add($bridgeMarker)
            $payloads.Add([byte[]]@(1))
        }
        TEXT {
            $text = (Decode $parts[2]).Replace("`r`n", "`n").Replace("`n", "`r`n")
            $payloads.Add([Text.Encoding]::Unicode.GetBytes($text + [char]0))
            $formats.Add(13)
        }
        IMAGE {
            $png = New-Object IO.MemoryStream(,[Convert]::FromBase64String($parts[2]))
            $bitmap = [Drawing.Image]::FromStream($png)
            $bmp = [IO.MemoryStream]::new()
            try {
                $bitmap.Save($bmp, [Drawing.Imaging.ImageFormat]::Bmp)
                $bmp.Position = 14
                $dib = New-Object byte[] ($bmp.Length - 14)
                $null = $bmp.Read($dib, 0, $dib.Length)
                $payloads.Add($png.ToArray())
                $formats.Add([Windows.Forms.DataFormats]::GetFormat('PNG').Id)
                $payloads.Add($dib)
                $formats.Add(8)
            } finally { $bitmap.Dispose(); $bmp.Dispose(); $png.Dispose() }
        }
        default { throw 'unsupported clipboard type' }
    }
    return [ClipVersion]::Publish($window.Handle, $sequence, $formats.ToArray(), $payloads.ToArray())
}
while ($null -ne ($request = [Console]::ReadLine())) {
    try { $reply = Exchange $request } catch { $reply = 'ERROR' }
    [Console]::WriteLine($reply)
    [Console]::Out.Flush()
}
SESSION_PS
    write_user_file "$HOME/.local/bin/wsl-clipboard-app" 755 <<'SESSION_LAUNCH'
#!/bin/bash
set -euo pipefail
umask 077
if (($# == 0)); then echo '用法: wsl-clipboard-app <前台 X11 图形程序> [参数...]' >&2; exit 2; fi
lib="$HOME/.local/lib/wsl-clipboard-session"
state=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/clipboard-session.XXXXXXXX")
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || :; done
    wait || :
    rm -rf -- "$state"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
display=
for number in {90..199}; do
    if [[ ! -e /tmp/.X11-unix/X$number && ! -e /tmp/.X${number}-lock ]]; then display=:$number; break; fi
done
[[ -n $display ]] || { echo '没有空闲 X11 显示号' >&2; exit 1; }
touch "$state/auth"
xauth -f "$state/auth" add "$display" . "$(mcookie)"
Xephyr "$display" -noreset -auth "$state/auth" -nolisten tcp -resizeable -screen 1100x760 -title 'WSL 双向剪贴板' &
server=$!
pids+=("$server")
export DISPLAY=$display XAUTHORITY="$state/auth" QT_QPA_PLATFORM=xcb GDK_BACKEND=x11
unset WAYLAND_DISPLAY
for _ in {1..20}; do
    kill -0 "$server" || exit 1
    if timeout 1 xdpyinfo >/dev/null 2>&1; then break; fi
    sleep .05
done
timeout 3 xdpyinfo >/dev/null
psbin=$(command -v powershell.exe || true)
[[ -x $psbin ]] || psbin=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
"$lib/session" "$psbin" "$lib/backend.ps1" &
bridge=$!
pids+=("$bridge")
openbox &
pids+=("$!")
# A private bus keeps toolkit single-instance forwarding and input contexts in this display.
dbus-run-session -- bash -c '
    if command -v fcitx5 >/dev/null; then
        export GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx
        fcitx5 --disable=wayland >/dev/null 2>&1 &
        im=$!
        trap '\''kill "$im" 2>/dev/null || : '\'' EXIT
    fi
    "$@"
' bash "$@" &
client=$!
pids+=("$client")
wait -n -p finished "$server" "$bridge" "$client"
[[ $finished == "$client" ]]
SESSION_LAUNCH
}

configure_opencode() {
    if [[ $OPENCODE_SESSION != true ]]; then
        local desktop override
        for desktop in /usr/share/applications/*.desktop; do
            override="$HOME/.local/share/applications/$(basename "$desktop")"
            if [[ -f $override ]] && grep -Fq "$HOME/.local/bin/wsl-opencode" "$override"; then
                write_user_file "$override" 644 < "$desktop"
            fi
        done
        if [[ -e $HOME/.local/bin/wsl-opencode ]]; then
            write_user_file "$HOME/.local/bin/wsl-opencode" 755 <<'DIRECT'
#!/bin/bash
exec ai.opencode "$@"
DIRECT
        fi
        return
    fi
    STEP=OpenCode启动
    local executable
    executable=$(command -v ai.opencode || true)
    [[ -x $executable ]] || fail '请先安装 OpenCode 桌面版，再使用 --opencode-session。'
    write_user_file "$HOME/.local/bin/wsl-opencode" 755 <<'OPENCODE'
#!/bin/bash
set -euo pipefail
if pgrep -u "$(id -u)" -x ai.opencode >/dev/null; then
    printf '请先完全退出 OpenCode，再打开独立剪贴板窗口。\n' >&2
    exit 1
fi
exec "$HOME/.local/bin/wsl-clipboard-app" ai.opencode --ozone-platform=x11 "$@"
OPENCODE
    # Match the package desktop IDs so Windows WSLg shortcuts use the override.
    local desktop
    for desktop in /usr/share/applications/*.desktop; do
        [[ -f $desktop ]] || continue
        if ! grep -Eq '^Exec=(/[^ ]*/)?ai\.opencode([[:space:]]|$)' "$desktop"; then continue; fi
        sed -E "s#^Exec=(/[^ ]*/)?ai\\.opencode#Exec=\"$HOME/.local/bin/wsl-opencode\"#" "$desktop" > "$TEMP_DIR/opencode.desktop"
        write_user_file "$HOME/.local/share/applications/$(basename "$desktop")" 644 < "$TEMP_DIR/opencode.desktop"
    done
}

stop_clipboard_bridges() {
    STEP=停止旧剪贴板桥接
    local unit pid exe owner
    for unit in wsl-clipboard-desktop.service xclip-linux-files-bridge.service xclip-bridge.service xclip-files-bridge.service; do
        if [[ $(user_systemctl show -p LoadState --value "$unit" 2>/dev/null) != not-found ]]; then
            user_systemctl disable --now "$unit" >/dev/null 2>&1 || true
        fi
    done
    # Match only this user's installed bridge binary, including replaced files.
    # Do not terminate unrelated PowerShell processes or Windows applications.
    for exe in /proc/[0-9]*/exe; do
        owner=$(stat -c %u "${exe%/exe}" 2>/dev/null) || continue
        [[ $owner == "$(id -u)" ]] || continue
        case "$(readlink "$exe" 2>/dev/null || true)" in
            "$HOME/.local/lib/wsl-clipboard-session/session"|"$HOME/.local/lib/wsl-clipboard-session/session (deleted)")
                pid=${exe%/exe}; pid=${pid##*/}
                kill -TERM "$pid" 2>/dev/null || true
                ;;
        esac
    done
}

configure_services() {
    STEP=后台服务
    write_user_file "$HOME/.local/bin/xclip-bridge-start" 755 <<'START'
#!/bin/bash
set -euo pipefail
mode=${1:-}
case "$mode" in
    files-out) watch_args=(--watch-files-out) ;;
    *) printf '未知剪贴板模式: %s\n' "$mode" >&2; exit 2 ;;
esac
for socket in /run/WSL/1_interop /run/WSL/*_interop; do
    if [[ -S $socket ]]; then
        export WSL_INTEROP="$socket"
        exec "$HOME/.local/bin/wsl-xclip" "${watch_args[@]}"
    fi
done
printf '未找到 WSL 互操作 socket\n' >&2
exit 1
START
    local service_dir="$CONFIG_DIR/systemd/user"
    write_user_file "$HOME/.local/bin/wsl-clipboard-desktop-start" 755 <<'DESKTOP_START'
#!/bin/bash
set -euo pipefail
for socket in /run/WSL/1_interop /run/WSL/*_interop; do
    if [[ -S $socket ]]; then
        export WSL_INTEROP="$socket"
        exec "$HOME/.local/lib/wsl-clipboard-session/session" \
            /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
            "$HOME/.local/lib/wsl-clipboard-session/backend.ps1" "${1:---files-only}"
    fi
done
printf '未找到 WSL 互操作 socket\n' >&2
exit 1
DESKTOP_START
    write_user_file "$service_dir/wsl-clipboard-desktop.service" 644 <<SERVICE
[Unit]
Description=Windows clipboard data for ordinary WSLg applications
StartLimitIntervalSec=0
[Service]
ExecStart=%h/.local/bin/wsl-clipboard-desktop-start --$([[ $CLIPBOARD_MODE == desktop ]] && echo desktop || echo files-only)
Environment="DISPLAY=$DISPLAY"
Environment="WSL_DISTRO_NAME=$WSL_DISTRO_NAME"
Environment=QT_QPA_PLATFORM=xcb
Restart=on-failure
RestartSec=3
KillMode=control-group
TimeoutStopSec=5
UMask=0077
[Install]
WantedBy=default.target
SERVICE
    write_user_file "$service_dir/xclip-linux-files-bridge.service" 644 <<SERVICE
[Unit]
Description=WSL Linux file clipboard publisher
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/bin/bash %h/.local/bin/xclip-bridge-start files-out
Environment="DISPLAY=$DISPLAY"
Environment="WSL_DISTRO_NAME=$WSL_DISTRO_NAME"
Restart=on-failure
RestartSec=3
SuccessExitStatus=143
KillMode=control-group
TimeoutStopSec=5
UMask=0077
[Install]
WantedBy=default.target
SERVICE
    if [[ $INSTALL_CHINESE == true ]]; then
        write_user_file "$CONFIG_DIR/systemd/user/wsl-fcitx5.service" 644 <<SERVICE
[Unit]
Description=Fcitx5 for WSLg
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/fcitx5 --disable=wayland --replace
Environment="DISPLAY=$DISPLAY"
Environment=GTK_IM_MODULE=fcitx
Environment=QT_IM_MODULE=fcitx
Environment=XMODIFIERS=@im=fcitx
Restart=on-failure
RestartSec=3
[Install]
WantedBy=default.target
SERVICE
    fi
    write_user_file "$service_dir/wsl-clipboard-cleanup.service" 644 <<'SERVICE'
[Unit]
Description=Remove clipboard file copies older than 24 hours
[Service]
Type=oneshot
ExecStart=%h/.local/lib/wsl-clipboard-session/stage-files --cleanup
SERVICE
    write_user_file "$service_dir/wsl-clipboard-cleanup.timer" 644 <<'TIMER'
[Unit]
Description=Hourly clipboard file cleanup
[Timer]
OnStartupSec=5min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
TIMER
    user_systemctl daemon-reload
    user_systemctl enable --now wsl-clipboard-cleanup.timer
    local legacy
    for legacy in xclip-bridge.service xclip-files-bridge.service; do
        if [[ $(user_systemctl show -p LoadState --value "$legacy") != not-found ]]; then
            user_systemctl disable --now "$legacy"
        fi
    done
    user_systemctl disable --now xclip-linux-files-bridge.service
    if [[ $CLIPBOARD_MODE == desktop || $CLIPBOARD_MODE == files ]]; then
        user_systemctl enable wsl-clipboard-desktop.service
        user_systemctl restart wsl-clipboard-desktop.service
    else
        user_systemctl disable --now wsl-clipboard-desktop.service
    fi
    case "$CLIPBOARD_MODE" in
        files-out)
            user_systemctl enable --now xclip-linux-files-bridge.service
            ;;
        native|session|desktop|files) ;;
    esac
    if [[ $INSTALL_CHINESE == true ]]; then
        user_systemctl enable wsl-fcitx5.service
        user_systemctl restart wsl-fcitx5.service
    else
        user_systemctl disable --now wsl-fcitx5.service >/dev/null 2>&1 || true
    fi
    if [[ $CLIPBOARD_MODE != native ]]; then sleep 3; fi
    if [[ $CLIPBOARD_MODE == files-out ]] && ! user_systemctl is-active --quiet xclip-linux-files-bridge.service; then
        journalctl --user -u xclip-linux-files-bridge.service -n 20 --no-pager
        fail 'Linux 到 Windows 文件增强未持续运行。'
    fi
    if [[ $CLIPBOARD_MODE == desktop || $CLIPBOARD_MODE == files ]] && ! user_systemctl is-active --quiet wsl-clipboard-desktop.service; then
        journalctl --user -u wsl-clipboard-desktop.service -n 20 --no-pager
        fail '普通 WSLg 剪贴板数据提供程序未持续运行。'
    fi
    if [[ $INSTALL_CHINESE == true ]] && ! user_systemctl is-active --quiet wsl-fcitx5.service; then
        journalctl --user -u wsl-fcitx5.service -n 20 --no-pager
        fail 'Fcitx5 用户服务启动失败，请检查以上日志后重新运行。'
    fi
}

main() {
    parse_args "$@"
    if [[ $OPENCODE_SESSION == true ]]; then CLIPBOARD_MODE=session; fi
    if [[ $DRY_RUN == true ]]; then
        printf '计划安装中文环境=%s，系统升级=%s\n' \
            "$([[ $INSTALL_CHINESE == true ]] && echo 是 || echo 否)" "$UPGRADE"
        printf '剪贴板模式=%s（files=保留原生文字及双向文件；desktop=普通WSLg窗口；native=仅WSLg原生；files-out=Linux到Windows文件增强；session=独立窗口双向剪贴板）\n' "$CLIPBOARD_MODE"
        printf '将保留原生 xclip，安装 wl-clipboard；增强桥接使用独立的 wsl-xclip 命令。\n'
        printf '已有配置备份至 ~/.local/state/wsl-ai-setup/backups。\n'
        printf '普通 WSLg 模式可直接运行 ai.opencode；独立窗口需显式选择 --opencode-session。\n'
        return
    fi
    if [[ $CHECK_ONLY == true ]]; then check_installation; return; fi
    preflight
    install_packages
    configure_wsl
    stop_clipboard_bridges
    if [[ $INSTALL_CHINESE == true ]]; then configure_chinese; fi
    install_file_staging
    install_clipboard
    if [[ $CLIPBOARD_MODE == session || $CLIPBOARD_MODE == desktop || $CLIPBOARD_MODE == files ]]; then install_file_session; fi
    configure_services
    configure_opencode
    STEP=完成
    log "配置备份位于 $BACKUP_DIR"
    check_installation
    if [[ $INSTALL_CHINESE == true ]]; then
        printf '\n请重新进入 WSL 用户会话，让中文与输入法环境变量生效。\n'
    fi
    if [[ $CLIPBOARD_MODE == session ]]; then
        printf '启动双向剪贴板窗口：~/.local/bin/wsl-clipboard-app 程序名 [参数...]\n'
    elif [[ $CLIPBOARD_MODE == desktop || $CLIPBOARD_MODE == files ]]; then
        printf '双向文件剪贴板服务已启用，文字和图片不由后台重发布，可直接打开普通 WSLg X11 应用。\n'
    else
        printf '普通 WSLg 窗口使用原生剪贴板。双向文件粘贴可选 --file-session。\n'
    fi
    printf '开机后进入该 WSL 用户会话时，systemd 按所选模式启动服务；重启后的实际粘贴仍需验收。\n'
}

main "$@"
