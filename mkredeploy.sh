#!/usr/bin/env bash
# mkredeploy.sh - snapshot this Debian system into ONE self-extracting redeploy script.
#
# The generated redeploy-<host>-<date>.sh contains (embedded in itself):
#   * the list of manually installed packages
#   * APT sources, pins and signing keys (third-party repos)
#   * Flatpak apps and remotes
#   * your desktop configs (niri, noctalia, kitty, ...) and system tweaks (greetd, systemd units, /usr/local)
# Copy that one file to a fresh Debian install and run it with sudo.
#
# Usage: ./mkredeploy.sh [options]   (see --help)
set -euo pipefail

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[!] $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
mkredeploy.sh - create a one-file redeploy script from this system

Options:
  -o, --output DIR     where to write the script            (default: current directory)
  -u, --user NAME      whose home-directory configs to save (default: the user who ran sudo)
  -a, --add PATH       also save PATH (relative to the home dir); repeatable
      --no-configs     packages and system settings only, no home-directory configs
      --keep-hardware  keep nvidia/microcode/xorg-video packages (dropped by default)
      --usr-local-max MB  skip any /usr/local/{bin,sbin,lib,etc} larger than this (default: 50;
                       0 = no limit). Keeps the script small if tools like pip/npm live there.
      --repack         rebuild locally-installed .deb packages (e.g. Atom, Tabby) with
                       dpkg-repack and embed them (needs: apt install dpkg-repack)
  -h, --help           show this help

Never saved by default (secrets): ~/.ssh, ~/.gnupg, keyrings, browser profiles,
Wi-Fi passwords (/etc/NetworkManager/system-connections), apt auth files.
Kernels are not saved either; the fresh install chooses its own.
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

command -v dpkg >/dev/null 2>&1 || die "This needs a Debian-based system."

# Reading system files needs root
if [ "$(id -u)" -ne 0 ]; then
    log "Re-running with sudo (needed to read system files)..."
    exec sudo -- "$0" "$@"
fi

OUT_DIR="$PWD"
CFG_USER="${SUDO_USER:-}"
KEEP_HW=0
NO_CONFIGS=0
REPACK=0
USR_LOCAL_MAX=50
EXTRA_PATHS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)     OUT_DIR="${2:?missing value for $1}"; shift 2 ;;
        -u|--user)       CFG_USER="${2:?missing value for $1}"; shift 2 ;;
        -a|--add)        EXTRA_PATHS+=("${2:?missing value for $1}"); shift 2 ;;
        --no-configs)    NO_CONFIGS=1; shift ;;
        --keep-hardware) KEEP_HW=1; shift ;;
        --repack)        REPACK=1; shift ;;
        --usr-local-max) USR_LOCAL_MAX="${2:?missing value for $1}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "Unknown option: $1 (try --help)" ;;
    esac
done

if [ -z "$CFG_USER" ]; then
    CFG_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')
fi
[ -n "$CFG_USER" ] || die "Could not determine a user; pass --user NAME."
USER_HOME=$(getent passwd "$CFG_USER" | cut -d: -f6 || true)
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || die "User '$CFG_USER' or its home directory does not exist."

STAGE=$(mktemp -d)
TPL=$(mktemp)
PAYLOAD=$(mktemp)
trap 'rm -rf "$STAGE" "$TPL" "$PAYLOAD"' EXIT

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
log "Collecting installed packages..."
apt-mark showmanual | sort -u > "$STAGE/manual-all.txt"

# Packages that came from a local .deb and are in no repository
{ apt list --installed 2>/dev/null | grep ',local\]' | cut -d/ -f1 | sort -u; } > "$STAGE/local-packages.txt" || true

EXCL='^linux-(image|headers|kbuild|compiler|source|libc-dev)'
if [ "$KEEP_HW" != 1 ]; then
    EXCL="$EXCL|^nvidia-|^libnvidia-|^firmware-nvidia|^xserver-xorg-video-|^intel-microcode\$|^amd64-microcode\$"
fi

{ grep -Ev "$EXCL" "$STAGE/manual-all.txt" || true; } > "$STAGE/pk1.txt"
{ grep -vxFf "$STAGE/local-packages.txt" "$STAGE/pk1.txt" || true; } > "$STAGE/packages.txt"
comm -23 "$STAGE/manual-all.txt" "$STAGE/packages.txt" | grep -vxFf "$STAGE/local-packages.txt" > "$STAGE/excluded-packages.txt" || true
rm -f "$STAGE/pk1.txt"

if [ -s "$STAGE/local-packages.txt" ]; then
    if [ "$REPACK" = 1 ]; then
        command -v dpkg-repack >/dev/null 2>&1 || die "--repack needs dpkg-repack (sudo apt install dpkg-repack)"
        mkdir -p "$STAGE/debs"
        while read -r p; do
            log "Repacking local package $p"
            ( cd "$STAGE/debs" && dpkg-repack "$p" ) || warn "Could not repack $p"
        done < "$STAGE/local-packages.txt"
    else
        warn "These packages are not in any repo (installed from local .deb files):"
        warn "  $(tr '\n' ' ' < "$STAGE/local-packages.txt")"
        warn "They are only listed, not saved. Use --repack to embed them."
    fi
fi

# ---------------------------------------------------------------------------
# 2. APT sources, pins and signing keys
# ---------------------------------------------------------------------------
# Append every file (or symlink) under $1 that no package owns to the list file $2
add_unowned() {
    local dir="$1" list="$2" f
    [ -d "$dir" ] || return 0
    while IFS= read -r -d '' f; do
        if ! dpkg -S "$f" >/dev/null 2>&1; then echo "$f" >> "$list"; fi
    done < <(find "$dir" -mindepth 1 \( -type f -o -type l \) -print0)
}

log "Collecting APT configuration..."
APT_LIST="$STAGE/apt.list"
: > "$APT_LIST"
for f in /etc/apt/sources.list /etc/apt/preferences; do
    if [ -f "$f" ]; then echo "$f" >> "$APT_LIST"; fi
done
for d in sources.list.d preferences.d trusted.gpg.d keyrings apt.conf.d; do
    add_unowned "/etc/apt/$d" "$APT_LIST"
done
# Key files referenced by Signed-By / signed-by (may live outside /etc/apt)
{ grep -rhoiE 'signed-by[=:][[:space:]]*/[^] ,]+' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true; } \
    | sed -E 's/^[^/]*//' | sort -u | while read -r k; do
        if [ -f "$k" ]; then echo "$k" >> "$APT_LIST"; fi
    done
sort -u "$APT_LIST" -o "$APT_LIST"
# Never save apt credentials
grep -v '/auth\.conf' "$APT_LIST" > "$APT_LIST.tmp" || true
mv "$APT_LIST.tmp" "$APT_LIST"

if [ -s "$APT_LIST" ]; then
    sed 's|^/||' "$APT_LIST" > "$STAGE/apt.rel"
    tar -czpf "$STAGE/apt.tar.gz" -C / -T "$STAGE/apt.rel"
fi

# ---------------------------------------------------------------------------
# 3. System settings and /usr/local
# ---------------------------------------------------------------------------
log "Collecting system settings..."
SYS_LIST="$STAGE/system.list"
: > "$SYS_LIST"
for p in /etc/greetd /etc/environment /var/lib/noctalia-greeter; do
    if [ -e "$p" ]; then echo "$p" >> "$SYS_LIST"; fi
done
add_unowned /etc/modprobe.d "$SYS_LIST"
add_unowned /etc/systemd/system "$SYS_LIST"     # custom units, drop-ins and enable/mask symlinks
add_unowned /etc/systemd/user "$SYS_LIST"
[[ "$USR_LOCAL_MAX" =~ ^[0-9]+$ ]] || die "--usr-local-max needs a number (MB)"
for p in /usr/local/bin /usr/local/sbin /usr/local/lib /usr/local/etc; do
    if [ -d "$p" ] && [ -n "$(ls -A "$p" 2>/dev/null)" ]; then
        sz=$(du -sm "$p" 2>/dev/null | cut -f1)
        if [ "$USR_LOCAL_MAX" -gt 0 ] && [ "${sz:-0}" -gt "$USR_LOCAL_MAX" ]; then
            warn "Skipping $p (${sz} MB is over the ${USR_LOCAL_MAX} MB limit; use --usr-local-max to change)"
        else
            echo "$p" >> "$SYS_LIST"
        fi
    fi
done
sort -u "$SYS_LIST" -o "$SYS_LIST"

if [ -s "$SYS_LIST" ]; then
    sed 's|^/||' "$SYS_LIST" > "$STAGE/system.rel"
    tar -czpf "$STAGE/system.tar.gz" -C / -T "$STAGE/system.rel"
fi

# ---------------------------------------------------------------------------
# 4. Home-directory configs
# ---------------------------------------------------------------------------
if [ "$NO_CONFIGS" != 1 ]; then
    log "Collecting configs for $CFG_USER ($USER_HOME)..."
    DEFAULT_CONFIGS=(
        .config/niri .config/noctalia .config/kitty .config/fuzzel
        .config/btop .config/cava .config/yazi .config/discordo
        .config/gtk-3.0 .config/gtk-4.0 .config/qt5ct .config/qt6ct
        .config/pcmanfm .config/libfm .config/mimeapps.list .config/user-dirs.dirs
        .config/systemd/user
        .bashrc .bash_profile .profile .bash_aliases .gitconfig
    )
    HOME_LIST="$STAGE/home.rel"
    : > "$HOME_LIST"
    for p in "${DEFAULT_CONFIGS[@]}" "${EXTRA_PATHS[@]}"; do
        p="${p#"$USER_HOME"/}"                      # accept absolute paths inside the home dir too
        case "$p" in /*|*..*) warn "Skipping '$p' (must be inside $USER_HOME)"; continue ;; esac
        case "$p" in .ssh*|.gnupg*|*keyrings*) warn "'$p' contains secrets; they will be stored in plain text in the redeploy script" ;; esac
        if [ -e "$USER_HOME/$p" ]; then echo "$p" >> "$HOME_LIST"; fi
    done
    if [ -s "$HOME_LIST" ]; then
        tar -czpf "$STAGE/home.tar.gz" -C "$USER_HOME" \
            --exclude='*/cache' --exclude='*/Cache' --exclude='*/.cache' \
            -T "$HOME_LIST"
        log "Saved configs: $(tr '\n' ' ' < "$HOME_LIST")"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Flatpak
# ---------------------------------------------------------------------------
if command -v flatpak >/dev/null 2>&1; then
    log "Collecting Flatpak apps..."
    { flatpak list --system --app --columns=origin,application 2>/dev/null || true; } > "$STAGE/flatpak-apps.txt"
    { flatpak remotes --system --columns=name,url 2>/dev/null || true; } > "$STAGE/flatpak-remotes.txt"
fi

# ---------------------------------------------------------------------------
# 6. Info
# ---------------------------------------------------------------------------
{
    echo "Host:        $(hostname)"
    echo "Date:        $(date -Is)"
    echo "Config user: $CFG_USER"
    echo "OS:          $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    echo "Kernel:      $(uname -r)"
    echo "GPU:         $(lspci 2>/dev/null | grep -Ei 'vga|3d|display' | cut -d: -f3- | head -n1 | sed 's/^ //')"
    echo "Packages:    $(wc -l < "$STAGE/packages.txt") (manual, repo-available)"
    echo "Local debs:  $(wc -l < "$STAGE/local-packages.txt")"
    echo "Excluded:    $(wc -l < "$STAGE/excluded-packages.txt") (kernels / hardware-specific)"
} > "$STAGE/info.txt"

# ---------------------------------------------------------------------------
# 7. Build the self-extracting redeploy script
# ---------------------------------------------------------------------------
cat > "$TPL" <<'RESTORE'

# ---------------------------------------------------------------------------
# Self-extracting redeploy script. Everything needed is embedded below.
# Run on a fresh Debian install:   sudo bash ./redeploy-*.sh [options]
# ---------------------------------------------------------------------------
set -euo pipefail

ARCHIVE_MARK="__ARCHIVE""_BELOW__"

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[!] $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: sudo bash ./redeploy-*.sh [options]
  -n, --dry-run      show what would happen, change nothing
  -y, --yes          do not ask for confirmation
  -u, --user NAME    restore home configs to this user (default: the original user)
      --no-packages  skip package installation
      --no-configs   skip home-directory configs
      --info         show what is inside this script and exit
  -h, --help         show this help
USAGE
}

main() {
    case "${1:-}" in -h|--help) usage; return 0 ;; esac
    if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi

    local DRY=0 PKGS=1 CONFIGS=1 YES=0 INFO=0 TARGET_USER="$SOURCE_USER"
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--dry-run)  DRY=1 ;;
            -y|--yes)      YES=1 ;;
            -u|--user)     TARGET_USER="${2:?missing value for $1}"; shift ;;
            --no-packages) PKGS=0 ;;
            --no-configs)  CONFIGS=0 ;;
            --info)        INFO=1 ;;
            -h|--help)     usage; return 0 ;;
            *)             die "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    command -v apt-get >/dev/null 2>&1 || die "This needs a Debian-based system."

    local START
    WORK=$(mktemp -d)          # global on purpose: the EXIT trap runs after main() returns
    trap 'rm -rf "$WORK"' EXIT
    START=$(LC_ALL=C awk -v m="$ARCHIVE_MARK" '$0 == m { print NR + 1; exit }' "$0")
    [ -n "$START" ] || die "Embedded archive not found (was this file edited or truncated?)"
    tail -n +"$START" "$0" | tar -xzf - -C "$WORK"

    echo "Snapshot of '$SOURCE_HOST' taken $SOURCE_DATE"
    sed 's/^/  /' "$WORK/info.txt"
    echo

    if [ "$INFO" = 1 ]; then
        echo "Packages to install:"; sed 's/^/  /' "$WORK/packages.txt" | column -c "${COLUMNS:-100}" 2>/dev/null || sed 's/^/  /' "$WORK/packages.txt"
        [ -s "$WORK/local-packages.txt" ] && { echo; echo "Local (non-repo) packages:"; sed 's/^/  /' "$WORK/local-packages.txt"; }
        [ -s "$WORK/flatpak-apps.txt" ]   && { echo; echo "Flatpak apps:"; sed 's/^/  /' "$WORK/flatpak-apps.txt"; }
        [ -f "$WORK/home.tar.gz" ]        && { echo; echo "Home configs:"; tar -tzf "$WORK/home.tar.gz" | cut -d/ -f1-3 | sort -u | sed 's/^/  /'; }
        return 0
    fi

    if [ "$DRY" != 1 ] && [ "$YES" != 1 ]; then
        read -rp "[?] Apply this snapshot to THIS machine? (y/N): " ans
        [[ "$ans" == [yY] ]] || { echo "Aborted."; return 1; }
    fi

    local REPORT=/root/redeploy-report.txt
    : > "$REPORT"
    export DEBIAN_FRONTEND=noninteractive
    local APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

    # ---- 1. APT sources, pins and keys (must come before installing packages) ----
    if [ -f "$WORK/apt.tar.gz" ]; then
        log "Restoring APT sources, pins and signing keys..."
        if [ "$DRY" = 1 ]; then tar -tzf "$WORK/apt.tar.gz" | sed 's/^/    would restore /'
        else tar -xzpf "$WORK/apt.tar.gz" -C /; fi
    fi

    # ---- 2. Packages ----
    if [ "$PKGS" = 1 ]; then
        local ALL=() AVAIL=() MISSING=() FAILED=() p
        mapfile -t ALL < "$WORK/packages.txt"
        if [ "$DRY" = 1 ]; then
            log "Would install ${#ALL[@]} packages from the repositories."
        else
            log "Updating package lists..."
            apt-get update || warn "apt-get update reported errors; check the restored sources."
            for p in "${ALL[@]}"; do
                if apt-cache show "$p" >/dev/null 2>&1; then AVAIL+=("$p"); else MISSING+=("$p"); fi
            done
            log "Installing ${#AVAIL[@]} packages (${#MISSING[@]} not available on this release)..."
            if [ "${#AVAIL[@]}" -gt 0 ] && ! apt-get install "${APT_OPTS[@]}" "${AVAIL[@]}"; then
                warn "Bulk install failed, retrying package by package..."
                for p in "${AVAIL[@]}"; do
                    apt-get install "${APT_OPTS[@]}" "$p" || FAILED+=("$p")
                done
            fi
            if [ "${#MISSING[@]}" -gt 0 ]; then
                { echo "Not available on this release (skipped):"; printf '  %s\n' "${MISSING[@]}"; echo; } >> "$REPORT"
            fi
            if [ "${#FAILED[@]}" -gt 0 ]; then
                { echo "Failed to install:"; printf '  %s\n' "${FAILED[@]}"; echo; } >> "$REPORT"
            fi
        fi

        # Locally installed .deb packages
        if [ -s "$WORK/local-packages.txt" ]; then
            if ls "$WORK"/debs/*.deb >/dev/null 2>&1; then
                log "Installing embedded local packages..."
                if [ "$DRY" = 1 ]; then ls "$WORK"/debs/*.deb | sed 's/^/    would install /'
                else apt-get install "${APT_OPTS[@]}" "$WORK"/debs/*.deb || warn "Some local packages failed to install."; fi
            else
                { echo "Were installed from local .deb files and must be installed by hand:"; sed 's/^/  /' "$WORK/local-packages.txt"; echo; } >> "$REPORT"
            fi
        fi

        # Flatpak
        if [ -s "$WORK/flatpak-apps.txt" ]; then
            log "Restoring Flatpak apps..."
            if [ "$DRY" = 1 ]; then sed 's/^/    would install /' "$WORK/flatpak-apps.txt"
            else
                command -v flatpak >/dev/null 2>&1 || apt-get install "${APT_OPTS[@]}" flatpak || warn "Could not install flatpak"
                if command -v flatpak >/dev/null 2>&1; then
                    local name url origin app
                    while read -r name url; do
                        [ -n "$name" ] || continue
                        if [ "$name" = flathub ]; then
                            flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
                                || warn "Could not add the flathub remote"
                        else
                            echo "Flatpak remote '$name' ($url) must be added by hand." >> "$REPORT"
                        fi
                    done < "$WORK/flatpak-remotes.txt"
                    while read -r origin app; do
                        [ -n "$app" ] || continue
                        flatpak install --system -y --noninteractive "$origin" "$app" \
                            || { warn "Could not install $app"; echo "Flatpak not installed: $app ($origin)" >> "$REPORT"; }
                    done < "$WORK/flatpak-apps.txt"
                fi
            fi
        fi
    fi

    # ---- 3. System settings and /usr/local (after packages, so package defaults do not clash) ----
    if [ -f "$WORK/system.tar.gz" ]; then
        log "Restoring system settings and /usr/local..."
        if [ "$DRY" = 1 ]; then tar -tzf "$WORK/system.tar.gz" | sed 's/^/    would restore /'
        else
            tar -xzpf "$WORK/system.tar.gz" -C /
            # numeric owners can differ between machines: re-own the greeter state to the greetd user
            if [ -d /var/lib/noctalia-greeter ] && [ -f /etc/greetd/config.toml ]; then
                local GU
                GU=$(awk -F'"' '/^user[[:space:]]*=/ {print $2; exit}' /etc/greetd/config.toml)
                if [ -n "$GU" ] && id "$GU" >/dev/null 2>&1; then
                    chown -R "$GU:$(id -gn "$GU")" /var/lib/noctalia-greeter
                fi
            fi
            systemctl daemon-reload || true
            fc-cache -f >/dev/null 2>&1 || true
        fi
    fi

    # ---- 4. Home configs ----
    if [ "$CONFIGS" = 1 ] && [ -f "$WORK/home.tar.gz" ]; then
        local HOME_DIR
        HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)
        if [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ]; then
            log "Restoring configs for $TARGET_USER (existing files are kept as *.~N~ backups)..."
            if [ "$DRY" = 1 ]; then tar -tzf "$WORK/home.tar.gz" | cut -d/ -f1-3 | sort -u | sed 's/^/    would restore ~\//'
            else runuser -u "$TARGET_USER" -- tar -xzp --backup=numbered -C "$HOME_DIR" -f - < "$WORK/home.tar.gz"; fi
        else
            warn "User '$TARGET_USER' does not exist here; create it and re-run with --user NAME --no-packages"
            echo "Home configs were NOT restored (user '$TARGET_USER' missing)." >> "$REPORT"
        fi
    fi

    echo
    if [ "$DRY" = 1 ]; then
        log "Dry run finished, nothing was changed."
    else
        log "Redeploy finished."
        if [ -s "$REPORT" ]; then warn "Things that need your attention (also saved in $REPORT):"; sed 's/^/    /' "$REPORT" >&2; fi
        echo "[*] Reboot recommended. Kernel and bootloader are not part of the snapshot."
    fi
}

main "$@"
exit $?
RESTORE

OUT="$OUT_DIR/redeploy-$(hostname)-$(date +%F).sh"
mkdir -p "$OUT_DIR"
tar -czf "$PAYLOAD" -C "$STAGE" .

{
    echo '#!/usr/bin/env bash'
    echo "# Generated by mkredeploy.sh on $(hostname) at $(date -Is)"
    printf 'SOURCE_HOST=%q\n' "$(hostname)"
    printf 'SOURCE_USER=%q\n' "$CFG_USER"
    printf 'SOURCE_DATE=%q\n' "$(date -Is)"
    cat "$TPL"
    echo "__ARCHIVE_BELOW__"
    cat "$PAYLOAD"
} > "$OUT"
chmod 755 "$OUT"
chown "$CFG_USER:" "$OUT" 2>/dev/null || true

SIZE=$(du -h "$OUT" | cut -f1)
echo
log "Created $OUT ($SIZE)"
sed 's/^/    /' "$STAGE/info.txt"
echo
echo "    Preview:  bash \"$OUT\" --info"
echo "    Dry run:  sudo bash \"$OUT\" --dry-run"
echo "    Redeploy: sudo bash \"$OUT\""
