#!/usr/bin/env bash
# Debian/Ubuntu WSL setup. Run as the Linux desktop user.
set -Eeuo pipefail
umask 022

DRY_RUN=false
CHECK_ONLY=false
INSTALL_CHINESE=true
CLIPBOARD_MODE=files
UPGRADE=false
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
默认启用双向文件桥接；文字和截图保留 WSLg 原生通道，仅在应用请求粘贴文件数据时传输，默认安装中文环境和 Fcitx5，不安装独立桌面。
  --dry-run         显示安装计划，保持系统当前状态
  --check           检查依赖和后台服务状态
  --with-chinese    安装中文字体、语言和 Fcitx5 输入法（默认）
  --without-chinese 不安装中文字体、语言和 Fcitx5 输入法
  --native          仅原生通道，显式关闭文件桥接
  --with-files      按应用数据请求触发的双向文件桥接（默认）
  --upgrade         显式执行系统软件升级
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
            --with-files) CLIPBOARD_MODE=files ;;
            --desktop-bridge|--file-session|--files-out|--opencode-session|--opencode-wayland)
                fail '旧主动导入/独立桌面模式已移除；请直接运行脚本使用按粘贴请求触发的文件桥接。' ;;
            --upgrade) UPGRADE=true ;;
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
    local failed=0 path
    for path in /usr/bin/xclip /usr/bin/wl-copy /usr/bin/wl-paste "$HOME/.local/lib/wsl-clipboard-session/stage-files"; do
        [[ -x $path ]] || { printf '缺少 %s\n' "$path" >&2; failed=1; }
    done
    if [[ $CLIPBOARD_MODE == files ]]; then
        [[ -x $HOME/.local/lib/wsl-clipboard-session/session ]] || failed=1
        user_systemctl is-active --quiet wsl-clipboard-desktop.service || failed=1
    fi
    user_systemctl is-active --quiet wsl-clipboard-cleanup.timer || failed=1
    if [[ $INSTALL_CHINESE == true ]]; then user_systemctl is-active --quiet wsl-fcitx5.service || failed=1; fi
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
    if [[ $CLIPBOARD_MODE == files ]]; then packages+=(g++ pkg-config qtbase5-dev libx11-dev); fi
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
    if sys.argv[1:] == ['--cleanup'] and not ROOT.exists():
        return
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

install_file_bridge() {
    STEP=按请求文件桥接
    local lib="$HOME/.local/lib/wsl-clipboard-session"
    cat > "$TEMP_DIR/session.cpp" <<'SESSION_CPP'
#include <QtCore>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <memory>
#include <cstring>

static QString mapPath(const QString &flag, const QString &path) {
    QProcess p; p.start("wslpath", {flag, "--", path});
    if (!p.waitForFinished(5000) || p.exitCode()) return {};
    QByteArray out = p.readAllStandardOutput();
    if (out.endsWith('\n')) out.chop(1);
    return QString::fromUtf8(out);
}

class Bridge {
    Display *d = nullptr;
    Window window = 0, observed = 0, sourceOwner = 0;
    Atom clipboard, targets, uri, gnome, png, bmp, utf8, plain, plainUtf8, html, textAtom, incr, property;
    QProcess host, stage;
    QTimer timer;
    std::unique_ptr<QSocketNotifier> notifier;
    QByteArray version = "-1", offered, offeredKind, loadingVersion, cached;
    QList<XSelectionRequestEvent> pending;
    bool receiving = false;
    Atom requested = 0;
    QByteArray incoming, exportVersion;
    QElapsedTimer sourceDeadline, stageDeadline;
    struct Transfer { Window requestor; Atom property; Atom target; QByteArray data; int offset; qint64 started; };
    QList<Transfer> transfers;
    static constexpr int chunk = 32768;
    static constexpr int maxUris = 4 * 1024 * 1024;
    static constexpr int maxImage = 64 * 1024 * 1024;
    Atom incomingTarget = 0;
    bool validPng(const QByteArray &bytes) {
        return bytes.size() <= maxImage && bytes.startsWith(QByteArray::fromHex("89504e470d0a1a0a"));
    }

    QList<QByteArray> exchange(const QByteArray &request) {
        if (host.state() != QProcess::Running || host.write(request + '\n') < 0) return {"ERROR"};
        QElapsedTimer deadline; deadline.start();
        // No event-loop reentry: only the explicit X11 data request calls PULL.
        while (!host.canReadLine() && deadline.elapsed() < 10000) {
            host.waitForReadyRead(20);
            if (host.state() == QProcess::NotRunning) break;
        }
        if (!host.canReadLine()) { QCoreApplication::exit(1); return {"ERROR"}; }
        return host.readLine().trimmed().split(' ');
    }
    void notify(const XSelectionRequestEvent &r, Atom result) {
        XEvent e{}; e.xselection.type = SelectionNotify;
        e.xselection.display = d; e.xselection.requestor = r.requestor;
        e.xselection.selection = r.selection; e.xselection.target = r.target;
        e.xselection.property = result; e.xselection.time = r.time;
        XSendEvent(d, r.requestor, False, 0, &e); XFlush(d);
    }
    void reply(const XSelectionRequestEvent &r, const QByteArray &data) {
        Atom prop = r.property == None ? r.target : r.property;
        if (data.size() <= chunk) {
            XChangeProperty(d, r.requestor, prop, r.target, 8, PropModeReplace,
                            reinterpret_cast<const unsigned char *>(data.constData()), data.size());
        } else {
            unsigned long size = data.size();
            XSelectInput(d, r.requestor, PropertyChangeMask);
            XChangeProperty(d, r.requestor, prop, incr, 32, PropModeReplace,
                            reinterpret_cast<unsigned char *>(&size), 1);
            transfers.append({r.requestor, prop, r.target, data, 0, QDateTime::currentMSecsSinceEpoch()});
        }
        notify(r, prop);
    }
    void failPending() { for (const auto &r : pending) notify(r, None); pending.clear(); }
    void cancelLoad() {
        loadingVersion.clear();
        if (stage.state() != QProcess::NotRunning) {
            stage.terminate(); if (!stage.waitForFinished(1000)) { stage.kill(); stage.waitForFinished(); }
        }
        failPending(); cached.clear();
    }
    void selectionRequest(const XSelectionRequestEvent &r) {
        if (r.selection != clipboard || offered.isEmpty() || XGetSelectionOwner(d, clipboard) != window) {
            notify(r, None); return;
        }
        const Atom prop = r.property == None ? r.target : r.property;
        if (r.target == targets) {
            const Atom fileFormats[] = {targets, uri, gnome};
            const Atom imageFormats[] = {targets, png};
            const bool image = offeredKind == "IMAGE";
            XChangeProperty(d, r.requestor, prop, XA_ATOM, 32, PropModeReplace,
                            reinterpret_cast<const unsigned char *>(image ? imageFormats : fileFormats), image ? 2 : 3);
            notify(r, prop); return; // Format probes never fetch Windows paths or stage files.
        }
        const bool supported = offeredKind == "IMAGE" ? r.target == png : (r.target == uri || r.target == gnome);
        if (!supported || r.requestor == window) { notify(r, None); return; }
        if (!cached.isEmpty()) {
            if (exchange("CHECK " + offered).first() != "CURRENT") { notify(r, None); return; }
            reply(r, r.target == gnome ? "copy\n" + QByteArray(cached).replace("\r\n", "\n") : cached); return;
        }
        pending.append(r);
        if (!loadingVersion.isEmpty()) return;
        const auto frame = exchange("PULL " + offered);
        if (frame.first() != offeredKind || frame.value(1) != offered || frame.size() < 3) { failPending(); return; }
        if (offeredKind == "IMAGE") {
            const auto image = QByteArray::fromBase64(frame.value(2));
            if (!validPng(image) || exchange("CHECK " + offered).first() != "CURRENT") { failPending(); return; }
            cached = image;
            for (const auto &request : pending) reply(request, cached);
            pending.clear(); return;
        }
        QStringList sources;
        for (const auto &path : frame.mid(2)) {
            QString source = mapPath("-u", QString::fromUtf8(QByteArray::fromBase64(path)));
            if (source.isEmpty()) { failPending(); return; }
            sources.append(source);
        }
        loadingVersion = offered;
        stageDeadline.start();
        stage.start(QDir::homePath() + "/.local/lib/wsl-clipboard-session/stage-files", sources);
        if (!stage.waitForStarted()) { loadingVersion.clear(); failPending(); }
    }
    void staged(int code, QProcess::ExitStatus status) {
        const auto load = loadingVersion; loadingVersion.clear();
        const auto result = QJsonDocument::fromJson(stage.readAllStandardOutput());
        QString root;
        QByteArray urls;
        if (result.isArray()) for (const auto &entry : result.array()) {
            if (!entry.isString()) { urls.clear(); break; }
            const auto path = entry.toString();
            if (root.isEmpty()) root = QFileInfo(QFileInfo(path).path()).path();
            urls += QUrl::fromLocalFile(path).toEncoded() + "\r\n";
        }
        const bool valid = !load.isEmpty() && load == offered && code == 0 &&
            status == QProcess::NormalExit && !urls.isEmpty() &&
            XGetSelectionOwner(d, clipboard) == window && exchange("CHECK " + load).first() == "CURRENT";
        if (!valid) {
            const QString cache = QDir::homePath() + "/.cache/wsl-clipboard/files/";
            if (root.startsWith(cache + "copy-")) QDir(root).removeRecursively();
            failPending(); return;
        }
        cached = urls;
        for (const auto &r : pending) reply(r, r.target == gnome ? "copy\n" + QByteArray(cached).replace("\r\n", "\n") : cached);
        pending.clear();
    }
    QByteArray getProperty(Atom &type, int &format, unsigned long &count) {
        unsigned char *raw = nullptr; unsigned long after = 0;
        const int limit = (requested == png || requested == bmp) ? maxImage : maxUris;
        if (XGetWindowProperty(d, window, property, 0, limit / 4, True, AnyPropertyType,
                               &type, &format, &count, &after, &raw) != Success) return {};
        // Xlib returns format-32 values as native unsigned longs.
        QByteArray bytes;
        if (!after && raw) bytes = QByteArray(reinterpret_cast<char *>(raw), count * (format == 32 ? sizeof(unsigned long) : 1));
        if (raw) XFree(raw);
        if (after) requested = 0;
        return bytes;
    }
    void exportFiles(const QByteArray &bytes) {
        if (XGetSelectionOwner(d, clipboard) != sourceOwner || bytes.size() > maxUris) return;
        QByteArray request = "EXPORT " + exportVersion;
        int count = 0;
        QByteArray uris = bytes;
        if (uris.startsWith("copy\n") || uris.startsWith("cut\n")) uris = uris.mid(uris.indexOf('\n') + 1);
        for (const auto &line : uris.split('\n')) {
            if (line.trimmed().isEmpty() || line.startsWith('#')) continue;
            QUrl url = QUrl::fromEncoded(line.trimmed(), QUrl::StrictMode);
            if (!url.isLocalFile() || ++count > 10000) return;
            const QString canonical = QFileInfo(url.toLocalFile()).canonicalFilePath();
            const QString cache = QFileInfo(QDir::homePath() + "/.cache/wsl-clipboard/files").canonicalFilePath();
            if (canonical.isEmpty() || (!cache.isEmpty() &&
                (canonical == cache || canonical.startsWith(cache + "/"))) || canonical.startsWith("/tmp/chatgpt-clipboard.")) return;
            const auto win = mapPath("-w", canonical);
            if (win.isEmpty()) return;
            request += " " + win.toUtf8().toBase64();
        }
        if (!count || XGetSelectionOwner(d, clipboard) != sourceOwner) return;
        const auto response = exchange(request);
        if (response.first() == "OK") version = response.value(1);
        // Never retry an old local offer after a newer Windows copy.
    }
    void exportData(const QByteArray &bytes, Atom type) {
        if (type != png && type != bmp) { exportFiles(bytes); return; }
        const bool image = type == png ? validPng(bytes) : (bytes.size() >= 14 && bytes.size() <= maxImage && bytes.startsWith("BM"));
        if (!image || XGetSelectionOwner(d, clipboard) != sourceOwner) return;
        const auto response = exchange("EXIMAGE " + exportVersion + " " + bytes.toBase64());
        if (response.first() == "OK") version = response.value(1);
    }
    void sourceData(const XSelectionEvent &e) {
        if (!requested || e.target != requested) return;
        if (e.property == None || XGetSelectionOwner(d, clipboard) != sourceOwner) { requested = 0; return; }
        Atom type = 0; int format = 0; unsigned long count = 0;
        const auto bytes = getProperty(type, format, count);
        if (!requested) return;
        if (requested == targets) {
            bool hasUris = false, hasGnome = false, hasPng = false, hasBmp = false, hasText = false;
            if (type == XA_ATOM && format == 32) for (unsigned long i = 0; i < count; i++) {
                unsigned long atom = 0; memcpy(&atom, bytes.constData() + i * sizeof(atom), sizeof(atom));
                if (atom == uri) hasUris = true;
                if (atom == gnome) hasGnome = true;
                if (atom == png) hasPng = true;
                if (atom == bmp) hasBmp = true;
                if (atom == utf8 || atom == plain || atom == plainUtf8 || atom == html || atom == textAtom || atom == XA_STRING) hasText = true;
            }
            if ((!hasUris && !hasGnome && hasText) || (!hasUris && !hasGnome && !hasPng && !hasBmp)) { requested = 0; return; }
            requested = hasUris ? uri : (hasGnome ? gnome : (hasPng ? png : bmp));
            XConvertSelection(d, clipboard, requested, property, window, CurrentTime); XFlush(d); return;
        }
        if (type == incr) { receiving = true; incomingTarget = requested; incoming.clear(); XFlush(d); return; }
        const Atom target = requested;
        requested = 0;
        if (format == 8) exportData(bytes, target);
    }
    void events() {
        while (XPending(d)) {
            XEvent e{}; XNextEvent(d, &e);
            if (e.type == SelectionRequest) selectionRequest(e.xselectionrequest);
            else if (e.type == SelectionClear && e.xselectionclear.selection == clipboard && XGetSelectionOwner(d, clipboard) != window) {
                offered.clear(); cancelLoad();
            } else if (e.type == SelectionNotify) sourceData(e.xselection);
            else if (e.type == PropertyNotify) {
                if (e.xproperty.window == window && e.xproperty.atom == property && receiving && e.xproperty.state == PropertyNewValue) {
                    Atom type = 0; int format = 0; unsigned long count = 0;
                    const auto bytes = getProperty(type, format, count);
                    if (!requested || format != 8 || incoming.size() + bytes.size() > ((incomingTarget == png || incomingTarget == bmp) ? maxImage : maxUris)) { receiving = false; requested = 0; }
                    else if (bytes.isEmpty()) { receiving = false; requested = 0; exportData(incoming, incomingTarget); incoming.clear(); }
                    else incoming += bytes;
                    XFlush(d);
                }
                for (int i = transfers.size() - 1; i >= 0; --i) {
                    auto &t = transfers[i];
                    if (e.xproperty.window != t.requestor || e.xproperty.atom != t.property || e.xproperty.state != PropertyDelete) continue;
                    auto bytes = t.data.mid(t.offset, chunk); t.offset += bytes.size();
                    XChangeProperty(d, t.requestor, t.property, t.target, 8, PropModeReplace,
                                    reinterpret_cast<const unsigned char *>(bytes.constData()), bytes.size());
                    if (bytes.isEmpty()) transfers.removeAt(i);
                    XFlush(d);
                }
            }
        }
    }
    void poll() {
        const auto state = exchange("POLL " + version);
        if (state.first() == "ECHO") {
            version = state.value(1);
            if (sourceOwner && sourceOwner == XGetSelectionOwner(d, clipboard)) exportVersion = version;
        }
        if (state.first() == "FILES" || state.first() == "IMAGE" || state.first() == "OTHER") {
            version = state.value(1);
            offered.clear(); cancelLoad(); requested = 0; receiving = false;
            offeredKind.clear();
            if (state.first() == "FILES" || state.first() == "IMAGE") {
                offered = version; offeredKind = state.first();
                XSetSelectionOwner(d, clipboard, window, CurrentTime); XFlush(d);
                observed = window;
            }
            // For text/HTML, invalidate only our old data. Do not clear X11
            // ownership: an empty selection can be mirrored back into Windows
            // before WSLg's native text owner finishes taking over.
        }
        const Window owner = XGetSelectionOwner(d, clipboard);
        if (owner != observed) {
            observed = owner;
            if (owner && owner != window) {
                sourceOwner = owner; exportVersion = version; requested = targets; receiving = false;
                sourceDeadline.start();
                XConvertSelection(d, clipboard, targets, property, window, CurrentTime); XFlush(d);
            }
        }
        if (requested && sourceDeadline.elapsed() > 5000) { requested = 0; receiving = false; }
        if (!loadingVersion.isEmpty() && stageDeadline.elapsed() > 120000) cancelLoad();
        const auto now = QDateTime::currentMSecsSinceEpoch();
        for (int i = transfers.size() - 1; i >= 0; --i) if (now - transfers[i].started > 30000) transfers.removeAt(i);
        events();
    }
public:
    bool start(const QString &powershell, const QString &scriptPath) {
        XSetErrorHandler([](Display *, XErrorEvent *) { return 0; });
        d = XOpenDisplay(nullptr); if (!d) return false;
        window = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 1, 1, 0, 0, 0);
        XSelectInput(d, window, PropertyChangeMask);
        clipboard = XInternAtom(d, "CLIPBOARD", False); targets = XInternAtom(d, "TARGETS", False);
        uri = XInternAtom(d, "text/uri-list", False); gnome = XInternAtom(d, "x-special/gnome-copied-files", False);
        png = XInternAtom(d, "image/png", False); bmp = XInternAtom(d, "image/bmp", False);
        utf8 = XInternAtom(d, "UTF8_STRING", False); plain = XInternAtom(d, "text/plain", False);
        plainUtf8 = XInternAtom(d, "text/plain;charset=utf-8", False); html = XInternAtom(d, "text/html", False);
        textAtom = XInternAtom(d, "TEXT", False);
        incr = XInternAtom(d, "INCR", False); property = XInternAtom(d, "_WSL_FILE_SOURCE", False);
        QFile file(scriptPath); if (!file.open(QIODevice::ReadOnly)) return false;
        QString source = QString::fromUtf8(file.readAll());
        const auto identity = QCryptographicHash::hash(qgetenv("WSL_DISTRO_NAME") + '\n' + qgetenv("DISPLAY"), QCryptographicHash::Sha256).toHex();
        source.prepend("$desktopIdentity = '" + QString::fromLatin1(identity) + "'\n");
        QByteArray utf16(reinterpret_cast<const char *>(source.utf16()), source.size() * 2);
        host.setProcessChannelMode(QProcess::ForwardedErrorChannel);
        host.start(powershell, {"-NoProfile", "-NonInteractive", "-STA", "-EncodedCommand", utf16.toBase64()});
        if (!host.waitForStarted()) return false;
        QObject::connect(&stage, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                         [this](int code, QProcess::ExitStatus status) { staged(code, status); });
        notifier = std::make_unique<QSocketNotifier>(ConnectionNumber(d), QSocketNotifier::Read);
        QObject::connect(notifier.get(), &QSocketNotifier::activated, [this](int) { events(); });
        QObject::connect(&timer, &QTimer::timeout, [this] { poll(); });
        timer.start(250); poll(); return true;
    }
    ~Bridge() {
        timer.stop(); notifier.reset();
        if (stage.state() != QProcess::NotRunning) { stage.terminate(); if (!stage.waitForFinished(1000)) { stage.kill(); stage.waitForFinished(); } }
        host.closeWriteChannel(); if (!host.waitForFinished(1000)) { host.kill(); host.waitForFinished(); }
        if (d) { XDestroyWindow(d, window); XCloseDisplay(d); }
    }
};
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (argc != 3) return 2;
    Bridge bridge;
    if (!bridge.start(QString::fromLocal8Bit(argv[1]), QString::fromLocal8Bit(argv[2]))) return 1;
    return app.exec();
}
SESSION_CPP
    g++ -std=c++17 -Wall -Wextra -O2 -fPIC "$TEMP_DIR/session.cpp" -o "$TEMP_DIR/session" $(pkg-config --cflags --libs Qt5Core x11)
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
$script:wslgProcessCache = @{}
function Test-WslgCommandLine([string]$commandLine) {
    return $commandLine -match '(?i)(?:^|\s)/wslg(?:\s|$)'
}
function Test-WslgProcess([uint32]$processId) {
    try {
        if (!$processId) { return $false }
        $process = [Diagnostics.Process]::GetProcessById([int]$processId)
        try {
            if ($process.ProcessName -notin @('msrdc', 'mstsc')) { return $false }
            $key = [string]$processId + ':' + [string]$process.StartTime.Ticks
        } finally { $process.Dispose() }
        if ($script:wslgProcessCache.ContainsKey($key)) { return $script:wslgProcessCache[$key] }
        $details = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
        if (!$details -or !$details.CommandLine) { return $false }
        $result = Test-WslgCommandLine $details.CommandLine
        if ($script:wslgProcessCache.Count -ge 128) { $script:wslgProcessCache.Clear() }
        $script:wslgProcessCache[$key] = $result
        return $result
    } catch {
        # Unknown process identity does not authorize an import or prove an echo.
        return $false
    }
}
function Test-WslgClipboardOwner { return (Test-WslgProcess ([ClipVersion]::OwnerProcessId())) }
function Test-ExportFilePath([string]$path) {
    # Use path components rather than escaped regular expressions so the same
    # checks work in Windows PowerShell 5.1 and PowerShell 7.
    $separator = [char]92
    $normalized = $path.Replace([char]47, $separator)
    $components = $normalized.ToLowerInvariant().Split($separator)
    $drive = $normalized.Length -ge 3 -and [char]::IsLetter($normalized[0]) -and
        $normalized[1] -eq [char]58 -and $normalized[2] -eq $separator
    $unc = $normalized.StartsWith(([string]$separator) * 2) -and $components.Count -ge 4 -and
        $components[2].Length -gt 0 -and $components[3].Length -gt 0
    if (!$drive -and !$unc) { return $false }
    for ($i = 0; $i -lt $components.Count; $i++) {
        if ($i + 2 -lt $components.Count -and $components[$i] -eq '.cache' -and
            $components[$i + 1] -eq 'wsl-clipboard' -and $components[$i + 2] -eq 'files') { return $false }
        if ($i + 1 -lt $components.Count -and $components[$i] -eq 'tmp' -and
            $components[$i + 1].StartsWith('chatgpt-clipboard.')) { return $false }
    }
    return $true
}
$window = New-Object Windows.Forms.Control
$mutex = [Threading.Mutex]::new($false, ('Local\NorthwindWSLClipboardDesktop.' + $desktopIdentity))
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (!$owned) { throw 'A file clipboard bridge is already running for this distribution/display' }
$bridgeMarker = [ClipVersion]::RegisterClipboardFormat('Northwind.WSL.FileClipboard.v1')
if (!$bridgeMarker) { throw 'Unable to register clipboard origin marker' }
$pngFormat = [ClipVersion]::RegisterClipboardFormat('PNG')
if (!$pngFormat) { throw 'Unable to register PNG clipboard format' }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
function Encode([string]$value) { [Convert]::ToBase64String($utf8.GetBytes($value)) }
function Decode([string]$value) { $utf8.GetString([Convert]::FromBase64String($value)) }
function Read-WindowsClipboard { return [Windows.Forms.Clipboard]::GetDataObject() }
function Test-WindowsImageFormat {
    return ([ClipVersion]::IsClipboardFormatAvailable($pngFormat) -or
        [ClipVersion]::IsClipboardFormatAvailable(2) -or [ClipVersion]::IsClipboardFormatAvailable(8) -or
        [ClipVersion]::IsClipboardFormatAvailable(17))
}
function Read-WindowsPng($data) {
    $stream = $null
    $bitmap = $null
    try {
        if ($data.GetDataPresent('PNG', $false)) {
            $value = $data.GetData('PNG', $false)
            if ($value -is [IO.MemoryStream]) { return ,$value.ToArray() }
            if ($value -is [byte[]]) { return ,$value }
        }
        if (!$data.GetDataPresent('Bitmap')) { return $null }
        $bitmap = $data.GetData('Bitmap')
        $stream = New-Object IO.MemoryStream
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
    }
}
function Publish-WindowsImage([string]$payload, [uint32]$sequence) {
    $png = $null; $pngOutput = $null; $bitmap = $null; $bmp = $null
    try {
        $bytes = [Convert]::FromBase64String($payload)
        if (!$bytes.Length -or $bytes.Length -gt 67108864) { return 'ERROR' }
        $png = New-Object IO.MemoryStream(,$bytes)
        $bitmap = [Drawing.Image]::FromStream($png)
        $pngOutput = New-Object IO.MemoryStream
        $bitmap.Save($pngOutput, [Drawing.Imaging.ImageFormat]::Png)
        $normalized = $pngOutput.ToArray()
        if ($normalized.Length -gt 67108864) { return 'ERROR' }
        $bmp = New-Object IO.MemoryStream
        $bitmap.Save($bmp, [Drawing.Imaging.ImageFormat]::Bmp)
        if ($bmp.Length -lt 14) { return 'ERROR' }
        $dib = New-Object byte[] ($bmp.Length - 14)
        $bmp.Position = 14
        $null = $bmp.Read($dib, 0, $dib.Length)
        $payloads = [Collections.Generic.List[byte[]]]::new()
        $payloads.Add($normalized); $payloads.Add($dib); $payloads.Add([byte[]]@(1))
        return [ClipVersion]::Publish($window.Handle, $sequence, [uint32[]]@($pngFormat, 8, $bridgeMarker), $payloads.ToArray())
    } catch { return 'ERROR' }
    finally {
        if ($pngOutput) { $pngOutput.Dispose() }; if ($bitmap) { $bitmap.Dispose() }; if ($bmp) { $bmp.Dispose() }; if ($png) { $png.Dispose() }
    }
}
function Exchange([string]$request) {
    $parts = $request.Split(' ')
    $sequence = [ClipVersion]::GetClipboardSequenceNumber()
    if ($parts[0] -eq 'CHECK') {
        if ($parts[1] -eq [string]$sequence) { return 'CURRENT' }
        return 'CHANGED'
    }
    if ($parts[0] -eq 'POLL') {
        if ($parts[1] -eq [string]$sequence) { return "SAME $sequence" }
        if ([ClipVersion]::IsClipboardFormatAvailable($bridgeMarker)) { return "OTHER $sequence" }
        if (Test-WslgClipboardOwner) { return "ECHO $sequence" }
        if ([ClipVersion]::IsClipboardFormatAvailable(15)) { return "FILES $sequence" }
        # Mixed rich-text/image selections are text and stay on the native path.
        if ([ClipVersion]::IsClipboardFormatAvailable(13)) { return "OTHER $sequence" }
        if (Test-WindowsImageFormat) { return "IMAGE $sequence" }
        return "OTHER $sequence"
    }
    if ($parts[0] -eq 'PULL') {
        if ($parts[1] -ne [string]$sequence) { return 'CHANGED' }
        if ([ClipVersion]::IsClipboardFormatAvailable($bridgeMarker)) { return 'ERROR' }
        if ([ClipVersion]::IsClipboardFormatAvailable(15)) {
            $data = Read-WindowsClipboard
            if (!$data -or !$data.GetDataPresent('FileDrop')) { return 'ERROR' }
            $paths = @(foreach ($path in $data.GetData('FileDrop')) { Encode $path })
            if (!$paths.Count -or $paths.Count -gt 10000) { return 'ERROR' }
            if ([ClipVersion]::GetClipboardSequenceNumber() -ne $sequence) { return 'CHANGED' }
            return "FILES $sequence " + ($paths -join ' ')
        }
        if ([ClipVersion]::IsClipboardFormatAvailable(13) -or !(Test-WindowsImageFormat)) { return 'ERROR' }
        $bytes = Read-WindowsPng (Read-WindowsClipboard)
        if (!$bytes -or $bytes.Length -gt 67108864) { return 'ERROR' }
        if ([ClipVersion]::GetClipboardSequenceNumber() -ne $sequence) { return 'CHANGED' }
        return "IMAGE $sequence " + [Convert]::ToBase64String($bytes)
    }
    if ($parts[0] -eq 'EXIMAGE') {
        if ($parts[1] -ne [string]$sequence) { return 'CHANGED' }
        return Publish-WindowsImage $parts[2] $sequence
    }
    if ($parts[0] -ne 'EXPORT') { return 'ERROR' }
    if ($parts[1] -ne [string]$sequence) { return 'CHANGED' }
    $paths = New-Object Collections.Specialized.StringCollection
    for ($i=2; $i -lt $parts.Length; $i++) {
        $path = Decode $parts[$i]
        if (!(Test-ExportFilePath $path)) { return 'ERROR' }
        [void]$paths.Add($path)
    }
    if (!$paths.Count -or $paths.Count -gt 10000) { return 'ERROR' }
    $header = New-Object byte[] 20
    $header[0] = 20
    $header[16] = 1
    $payloads = [Collections.Generic.List[byte[]]]::new()
    $payloads.Add([byte[]]($header + [Text.Encoding]::Unicode.GetBytes(($paths -join [char]0) + [char]0 + [char]0)))
    $payloads.Add([byte[]]@(1))
    return [ClipVersion]::Publish($window.Handle, $sequence, [uint32[]]@(15, $bridgeMarker), $payloads.ToArray())
}
while ($null -ne ($request = [Console]::ReadLine())) {
    try { $reply = Exchange $request } catch { $reply = 'ERROR' }
    [Console]::WriteLine($reply)
    [Console]::Out.Flush()
}
SESSION_PS
}

migrate_legacy() {
    STEP=清理旧入口
    printf '#!/bin/sh\nexec /usr/bin/xclip "$@"\n' > "$TEMP_DIR/native-xclip"
    if ! cmp -s /usr/local/bin/xclip "$TEMP_DIR/native-xclip"; then
        backup /usr/local/bin/xclip
        sudo install -m 755 "$TEMP_DIR/native-xclip" /usr/local/bin/xclip
    fi
    local desktop override path
    for desktop in /usr/share/applications/*.desktop; do
        override="$HOME/.local/share/applications/$(basename "$desktop")"
        if [[ -f $desktop && -f $override ]] && grep -Fq "$HOME/.local/bin/wsl-opencode" "$override"; then
            write_user_file "$override" 644 < "$desktop"
        fi
    done
    if [[ -e $HOME/.local/bin/wsl-opencode ]]; then
        write_user_file "$HOME/.local/bin/wsl-opencode" 755 <<'DIRECT'
#!/bin/sh
exec ai.opencode "$@"
DIRECT
    fi
    if [[ -e $HOME/.local/bin/wsl-clipboard-app ]]; then
        write_user_file "$HOME/.local/bin/wsl-clipboard-app" 755 <<'DIRECT_APP'
#!/bin/sh
exec "$@"
DIRECT_APP
    fi
    for path in "$HOME/.local/bin/wsl-xclip" "$HOME/.local/bin/xclip-bridge-start"; do
        [[ -e $path ]] || continue
        backup "$path"
        rm -- "$path"
    done
}

configure_services() {
    STEP=后台服务
    local service_dir="$CONFIG_DIR/systemd/user"
    write_user_file "$HOME/.local/bin/wsl-clipboard-desktop-start" 755 <<'DESKTOP_START'
#!/bin/bash
set -euo pipefail
for socket in /run/WSL/1_interop /run/WSL/*_interop; do
    if [[ -S $socket ]]; then
        export WSL_INTEROP="$socket"
        exec "$HOME/.local/lib/wsl-clipboard-session/session" \
            /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
            "$HOME/.local/lib/wsl-clipboard-session/backend.ps1"
    fi
done
printf '未找到 WSL 互操作 socket\n' >&2
exit 1
DESKTOP_START
    write_user_file "$service_dir/wsl-clipboard-desktop.service" 644 <<SERVICE
[Unit]
Description=WSL file clipboard transfer on application data requests
StartLimitIntervalSec=0
[Service]
ExecStart=%h/.local/bin/wsl-clipboard-desktop-start
Environment="DISPLAY=$DISPLAY"
Environment="WSL_DISTRO_NAME=$WSL_DISTRO_NAME"
Restart=on-failure
RestartSec=3
KillMode=control-group
TimeoutStopSec=5
UMask=0077
[Install]
WantedBy=default.target
SERVICE
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
    if [[ $INSTALL_CHINESE == true ]]; then
        write_user_file "$service_dir/wsl-fcitx5.service" 644 <<SERVICE
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
    user_systemctl daemon-reload
    user_systemctl enable --now wsl-clipboard-cleanup.timer
    if [[ $CLIPBOARD_MODE == files ]]; then user_systemctl enable --now wsl-clipboard-desktop.service; fi
    if [[ $INSTALL_CHINESE == true ]]; then
        user_systemctl enable wsl-fcitx5.service
        user_systemctl restart wsl-fcitx5.service
    fi
    if [[ $CLIPBOARD_MODE == files ]]; then
        sleep 2
        if ! user_systemctl is-active --quiet wsl-clipboard-desktop.service; then
            journalctl --user -u wsl-clipboard-desktop.service -n 20 --no-pager
            fail '按请求文件桥接未持续运行。'
        fi
    fi
}

main() {
    parse_args "$@"
    if [[ $DRY_RUN == true ]]; then
        printf '计划安装中文环境=%s，系统升级=%s\n' "$([[ $INSTALL_CHINESE == true ]] && echo 是 || echo 否)" "$UPGRADE"
        printf '剪贴板模式=%s；Windows 文件仅在 Linux 应用请求文件数据时传输。\n' "$CLIPBOARD_MODE"
        printf 'Windows 复制、窗口切换和格式探测不读取文件列表、不创建缓存；文字图片保留原生通道。\n'
        return
    fi
    if [[ $CHECK_ONLY == true ]]; then check_installation; return; fi
    preflight
    install_packages
    configure_wsl
    stop_clipboard_bridges
    if [[ $INSTALL_CHINESE == true ]]; then configure_chinese; fi
    install_file_staging
    if [[ $CLIPBOARD_MODE == files ]]; then install_file_bridge; fi
    migrate_legacy
    configure_services
    STEP=完成
    check_installation
    log "配置备份位于 $BACKUP_DIR"
    printf '文件传输由 Linux 应用的数据请求触发；本机和远程桌面使用同一规则。\n'
    if [[ $INSTALL_CHINESE == true ]]; then printf '请重新进入 WSL 用户会话，让中文与输入法环境变量生效。\n'; fi
}

main "$@"
