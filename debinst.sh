#!/usr/bin/env bash
# Debian (trixie) installer: Btrfs + Limine + CachyOS-style kernel (BORE + ThinLTO)
# + Niri + Noctalia + Atom / Tabby / discordo / yazi / pcmanfm + Flatpak + Bazaar
# Run as root from a Debian live ISO with working network and UEFI boot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

TARGET="/mnt"

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[!] $*" >&2; exit 1; }

echo "=========================================================="
echo "   Debian + Optimized Kernel + Limine + Niri + Noctalia    "
echo "=========================================================="

# ---------------------------------------------------------------
# 0. Sanity checks and host tools
# ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ]            || die "Run this script as root."
[ -d /sys/firmware/efi ]        || die "Not booted in UEFI mode. Limine setup here is UEFI-only."
command -v apt-get &>/dev/null  || die "This script expects a Debian-based live environment."

log "Installing host utilities..."
apt-get update -qq
apt-get install -y -qq debootstrap debian-archive-keyring dosfstools btrfs-progs \
    gdisk parted util-linux pciutils coreutils

# ---------------------------------------------------------------
# 1. Target drive selection
# ---------------------------------------------------------------
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E "disk" || true
echo ""
read -rp "[?] Enter target disk device (e.g. /dev/nvme0n1 or /dev/sda): " TARGET_DISK

[ -b "$TARGET_DISK" ] || die "$TARGET_DISK is not a valid block device!"

if lsblk -rno MOUNTPOINTS "$TARGET_DISK" | grep -qE '(^/$|live)'; then
    die "$TARGET_DISK appears to hold the running live system. Pick another disk."
fi

read -rp "[!] WARNING: ALL DATA ON $TARGET_DISK WILL BE WIPED. Continue? (y/N): " CONFIRM
[[ "$CONFIRM" == [yY] ]] || { echo "Aborted."; exit 1; }

# ---------------------------------------------------------------
# 2. Configuration
# ---------------------------------------------------------------
read -rp "[?] Primary username [admin]: " USERNAME
USERNAME=${USERNAME:-admin}
read -rp "[?] Hostname [debian-node]: " NEW_HOSTNAME
NEW_HOSTNAME=${NEW_HOSTNAME:-debian-node}
read -rp "[?] Timezone [UTC] (e.g. Europe/Warsaw): " TIMEZONE
TIMEZONE=${TIMEZONE:-UTC}

while true; do
    read -rsp "[?] Password for $USERNAME: " USER_PASSWORD; echo
    read -rsp "[?] Repeat password: " USER_PASSWORD2; echo
    [ -n "$USER_PASSWORD" ] && [ "$USER_PASSWORD" = "$USER_PASSWORD2" ] && break
    warn "Passwords empty or do not match, try again."
done

read -rp "[?] SSH public key (optional): " SSH_PUB_KEY

echo ""
echo "Login manager:"
echo "  1) greetd + Noctalia Greeter (matches the shell; falls back to tuigreet)  [default]"
echo "  2) greetd + tuigreet (tiny terminal greeter)"
echo "  3) None (log in on tty1, niri starts automatically)"
read -rp "[?] Select login manager [1]: " LOGIN_CHOICE
LOGIN_CHOICE=${LOGIN_CHOICE:-1}

echo ""
echo "Kernel choice:"
echo "  1) CachyOS-patched kernel built from source: BORE scheduler + Clang ThinLTO  [default]"
echo "     (needs ~16 GB RAM, ~25 GB free disk, and roughly 30-90+ min of compile time)"
echo "  2) XanMod LTS from apt (x86-64-vN optimized, but no BORE / LTO)"
echo "  3) Debian stock kernel"
read -rp "[?] Select kernel [1]: " KERNEL_CHOICE
KERNEL_CHOICE=${KERNEL_CHOICE:-1}

# CPU ISA level (1-3) used for the optimized kernel builds
LD_HELP=$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null || true)
if   grep -q 'x86-64-v3 (supported' <<<"$LD_HELP"; then XLEVEL=3
elif grep -q 'x86-64-v2 (supported' <<<"$LD_HELP"; then XLEVEL=2
else                                                    XLEVEL=1
fi
XANMOD_PKG="linux-xanmod-lts-x64v${XLEVEL}"
log "Detected x86-64 level v$XLEVEL"

# ---------------------------------------------------------------
# 3. Partitioning (GPT: 1G ESP + Btrfs root)
# ---------------------------------------------------------------
cleanup() { umount -R "$TARGET" 2>/dev/null || true; }
trap cleanup EXIT

log "Wiping and partitioning $TARGET_DISK..."
umount -R "$TARGET" 2>/dev/null || true
lsblk -rno PATH "$TARGET_DISK" | tac | xargs -r -n1 umount 2>/dev/null || true
swapoff -a 2>/dev/null || true

wipefs -af "$TARGET_DISK"
sgdisk --zap-all "$TARGET_DISK"
sgdisk -n1:0:+1G -t1:EF00 -c1:EFI-SYSTEM \
       -n2:0:0   -t2:8300 -c2:LINUX-ROOT "$TARGET_DISK"
partprobe "$TARGET_DISK"
udevadm settle
sleep 2

if [[ "$TARGET_DISK" =~ [0-9]$ ]]; then
    PART_EFI="${TARGET_DISK}p1"
    PART_ROOT="${TARGET_DISK}p2"
else
    PART_EFI="${TARGET_DISK}1"
    PART_ROOT="${TARGET_DISK}2"
fi

# ---------------------------------------------------------------
# 4. Filesystems and subvolumes
# ---------------------------------------------------------------
log "Formatting partitions..."
mkfs.vfat -F32 -n "EFI" "$PART_EFI"
mkfs.btrfs -f -L "DEBIAN_ROOT" "$PART_ROOT"

log "Creating Btrfs subvolumes..."
mount "$PART_ROOT" "$TARGET"
for sv in @ @home @log @pkg; do btrfs subvolume create "$TARGET/$sv"; done
umount "$TARGET"

log "Mounting subvolumes..."
MOPTS="noatime,compress=zstd:1"
mount -o "$MOPTS,subvol=@" "$PART_ROOT" "$TARGET"
mkdir -p "$TARGET"/{boot,home,var/log,var/cache/apt}
mount -o "$MOPTS,subvol=@home" "$PART_ROOT" "$TARGET/home"
mount -o "$MOPTS,subvol=@log"  "$PART_ROOT" "$TARGET/var/log"
mount -o "$MOPTS,subvol=@pkg"  "$PART_ROOT" "$TARGET/var/cache/apt"

# ---------------------------------------------------------------
# 5. Bootstrap
# ---------------------------------------------------------------
log "Bootstrapping Debian trixie..."
debootstrap --arch=amd64 trixie "$TARGET" http://deb.debian.org/debian/

# The ESP is mounted at /boot (not /boot/efi) so kernels and initrds that
# Debian installs land on FAT, where Limine can read them. This keeps
# kernel updates working without manual copying.
mount "$PART_EFI" "$TARGET/boot"

# ---------------------------------------------------------------
# 6. fstab
# ---------------------------------------------------------------
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")

cat > "$TARGET/etc/fstab" <<EOT
UUID=$ROOT_UUID  /               btrfs  $MOPTS,subvol=@     0 0
UUID=$ROOT_UUID  /home           btrfs  $MOPTS,subvol=@home 0 0
UUID=$ROOT_UUID  /var/log        btrfs  $MOPTS,subvol=@log  0 0
UUID=$ROOT_UUID  /var/cache/apt  btrfs  $MOPTS,subvol=@pkg  0 0
UUID=$EFI_UUID   /boot           vfat   umask=0077          0 2
EOT

# ---------------------------------------------------------------
# 7. Chroot prerequisites
# ---------------------------------------------------------------
for dir in proc sys dev dev/pts; do
    mount --bind "/$dir" "$TARGET/$dir"
done
cp /etc/resolv.conf "$TARGET/etc/resolv.conf"

mkdir -p "$TARGET/usr/local/lib" "$TARGET/usr/local/sbin" "$TARGET/root"

# ---- shared helper functions (used inside the chroot) ----
cat > "$TARGET/usr/local/lib/debinst-lib.sh" <<'LIB'
log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }

# Newest version tag of a git repo (empty if none)
latest_tag() {
    git ls-remote --tags --refs --sort=-v:refname "$1" 2>/dev/null | sed -n '1s|.*refs/tags/||p'
}

# Shallow-clone the newest tag, or the default branch if no tag is found
clone_latest() {
    local tag
    tag=$(latest_tag "$1")
    if [ -n "$tag" ]; then
        git clone --depth=1 --branch "$tag" "$1" "$2"
    else
        git clone --depth=1 "$1" "$2"
    fi
}

# Install packages one by one; a missing package only produces a warning
try_install() {
    local p
    for p in "$@"; do
        apt-get install -y "$p" || warn "Could not install $p (skipping)"
    done
}
LIB

# ---- Noctalia v5 (native Wayland shell; no Quickshell needed) ----
cat > "$TARGET/usr/local/sbin/install-noctalia.sh" <<'QS'
#!/usr/bin/env bash
# Installs Noctalia v5 (native Wayland shell, currently beta) from Noctalia's APT repo,
# falling back to a source build. Safe to re-run. Usage: install-noctalia.sh <username>
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
. /usr/local/lib/debinst-lib.sh

install_noctalia_from_repo() {
    # Remove the old v4-style entry (it 404s and would break every "apt update")
    rm -f /etc/apt/sources.list.d/noctalia.list /etc/apt/keyrings/noctalia.gpg
    # v5 Debian repo: keyring package + .sources file (per docs.noctalia.dev)
    curl -fsSL -o /tmp/nickh-archive-keyring.deb https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb \
    && dpkg -i /tmp/nickh-archive-keyring.deb \
    && curl -fsSL -o /etc/apt/sources.list.d/noctalia-trixie.sources https://pkg.noctalia.dev/deb/noctalia-trixie.sources \
    && apt-get update \
    && apt-get install -y noctalia
}

build_noctalia_from_source() {
    log "Installing Noctalia build dependencies..."
    apt-get install -y meson g++ just git \
        libwayland-dev wayland-protocols libegl-dev libgles-dev \
        libfreetype-dev libfontconfig-dev libcairo2-dev libpango1.0-dev librsvg2-dev \
        libxkbcommon-dev libglib2.0-dev libwebp-dev libcurl4-gnutls-dev \
        libmd4c-dev nlohmann-json3-dev libsdbus-c++-dev libsecret-1-dev \
        libsodium-dev libstb-dev libtomlplusplus-dev \
        libpipewire-0.3-dev libpam0g-dev libpolkit-agent-1-dev libpolkit-gobject-1-dev \
        libqalculate-dev libwireplumber-0.5-dev libxml2-dev
    # Listed in some versions of the docs; missing ones are skipped
    try_install libjemalloc-dev libharfbuzz-dev libjxl-dev libsndfile1-dev libepoxy-dev

    log "Building Noctalia from source..."
    rm -rf /tmp/noctalia
    clone_latest https://github.com/noctalia-dev/noctalia.git /tmp/noctalia
    cd /tmp/noctalia
    just configure release
    just build release
    just install release
    cd /
    rm -rf /tmp/noctalia
}

# The APT repo is community-maintained; the Noctalia team itself supports the source build.
# Set NOCTALIA_FROM_SOURCE=1 to skip the repo.
if [ "${NOCTALIA_FROM_SOURCE:-0}" != "1" ] && install_noctalia_from_repo; then
    log "Noctalia installed from its APT repo"
else
    warn "Building Noctalia from source (slow)"
    rm -f /etc/apt/sources.list.d/noctalia-trixie.sources /etc/apt/sources.list.d/noctalia.list
    apt-get update
    build_noctalia_from_source
fi

# Helpers Noctalia can use (missing ones are skipped)
try_install brightnessctl imagemagick python3 cliphist wlsunset bluez \
    fonts-roboto fonts-noto-core fonts-noto-color-emoji

# Autostart. Preferred (documented by Noctalia): a spawn-at-startup line in niri's config.
USERNAME=${1:-}
NIRI_CFG="/home/$USERNAME/.config/niri/config.kdl"
if [ -n "$USERNAME" ] && [ -f "$NIRI_CFG" ]; then
    if ! grep -qE 'spawn-at-startup[[:space:]]+"noctalia"' "$NIRI_CFG"; then
        printf '\nspawn-at-startup "noctalia"\n' >> "$NIRI_CFG"
    fi
    # remove a unit left over from earlier versions, so Noctalia is not started twice
    rm -f /etc/systemd/user/noctalia.service /etc/systemd/user/niri.service.wants/noctalia.service
else
    # No niri config to edit: start it through a systemd user unit that niri.service pulls in
    warn "No niri config found at $NIRI_CFG, using a systemd user unit for autostart instead"
    mkdir -p /etc/systemd/user /etc/systemd/user/niri.service.wants
    cat > /etc/systemd/user/noctalia.service <<'EOT'
[Unit]
Description=Noctalia shell
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/bin/env noctalia
Restart=on-failure
RestartSec=2

[Install]
WantedBy=niri.service
EOT
    ln -sf /etc/systemd/user/noctalia.service /etc/systemd/user/niri.service.wants/noctalia.service
fi

log "Noctalia installed."
QS
chmod +x "$TARGET/usr/local/sbin/install-noctalia.sh"

# ---- CachyOS-patched kernel: BORE + Clang ThinLTO (re-runnable after install) ----
cat > "$TARGET/usr/local/sbin/build-cachyos-kernel.sh" <<'KB'
#!/usr/bin/env bash
# Builds a kernel.org kernel with the CachyOS patchset (BORE scheduler) using
# Clang + ThinLTO, packages it as .deb files and installs them.
# Usage: build-cachyos-kernel.sh [x86-64-level 1-3]
# Optional env: CACHY_MAJOR (e.g. 6.18) and CACHY_MINOR (e.g. 4) to pin a version.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
. /usr/local/lib/debinst-lib.sh

XLEVEL=${1:-3}
BUILD_DIR=/usr/src/cachyos-build
MAKE_ARGS=(LLVM=1 LLVM_IAS=1)

MEM_GB=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
[ "$MEM_GB" -ge 12 ] || warn "Only ~${MEM_GB} GB RAM detected; the ThinLTO link step may run out of memory."

log "Installing kernel build dependencies..."
apt-get install -y bc bison flex cpio rsync kmod dwarves fakeroot debhelper dpkg-dev \
    libelf-dev libssl-dev libncurses-dev python3 patch xz-utils zstd curl \
    clang lld llvm

# Work out which kernel version CachyOS currently ships
if [ -z "${CACHY_MAJOR:-}" ] || [ -z "${CACHY_MINOR:-}" ]; then
    RAW=$(curl -fsSL https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos/PKGBUILD || true)
    CACHY_MAJOR=$(awk -F= '/^_major=/{split($2,a," "); print a[1]; exit}' <<<"$RAW" | tr -d "\"'")
    CACHY_MINOR=$(awk -F= '/^_minor=/{split($2,a," "); print a[1]; exit}' <<<"$RAW" | tr -d "\"'")
fi
if [ -z "$CACHY_MAJOR" ] || [ -z "$CACHY_MINOR" ]; then
    warn "Could not determine the CachyOS kernel version. Re-run with CACHY_MAJOR=x.y CACHY_MINOR=z set."
    exit 1
fi
if [ "$CACHY_MINOR" = "0" ]; then KVER="$CACHY_MAJOR"; else KVER="$CACHY_MAJOR.$CACHY_MINOR"; fi
log "Building kernel $KVER (CachyOS patches for $CACHY_MAJOR, x86-64-v$XLEVEL)"

PATCHES="https://raw.githubusercontent.com/CachyOS/kernel-patches/master/$CACHY_MAJOR"
CONFIG_URL="https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos/config"
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${CACHY_MAJOR%%.*}.x/linux-$KVER.tar.xz"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

curl -fL --retry 3 -o linux.tar.xz "$TARBALL_URL"
curl -fL --retry 3 -o 0001-cachyos-base-all.patch "$PATCHES/all/0001-cachyos-base-all.patch"
curl -fL --retry 3 -o 0002-bore-cachy.patch       "$PATCHES/sched/0001-bore-cachy.patch"
curl -fL --retry 3 -o 0003-dkms-clang.patch       "$PATCHES/misc/dkms-clang.patch"
curl -fL --retry 3 -o config                      "$CONFIG_URL"

tar -xf linux.tar.xz
SRC=$(find . -maxdepth 1 -type d -name 'linux-*' | head -n1)
cd "$SRC"

for p in ../0001-cachyos-base-all.patch ../0002-bore-cachy.patch ../0003-dkms-clang.patch; do
    log "Applying $(basename "$p")"
    patch -Np1 -i "$p"
done

cp ../config .config

# CachyOS options: BORE scheduler, ThinLTO, generic x86-64-vN target
scripts/config \
    -e CACHY \
    -e SCHED_BORE \
    -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU \
    --set-val X86_64_VERSION "$XLEVEL" \
    -e LTO_CLANG_THIN \
    -d RUST \
    -d LOCALVERSION_AUTO \
    --set-str LOCALVERSION "-cachyos-bore-lto"

make "${MAKE_ARGS[@]}" olddefconfig

grep -q '^CONFIG_SCHED_BORE=y'     .config || { warn "BORE did not end up enabled in .config"; exit 1; }
grep -q '^CONFIG_LTO_CLANG_THIN=y' .config || { warn "ThinLTO did not end up enabled in .config"; exit 1; }

export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=debian
export DEBEMAIL=root@localhost DEBFULLNAME="Kernel Builder"

log "Compiling (this takes a while)..."
make "${MAKE_ARGS[@]}" -j"$(nproc)" KDEB_COMPRESS=zstd DPKG_FLAGS=-d bindeb-pkg

cd "$BUILD_DIR"
IMG=$(ls linux-image-*.deb | grep -v -- '-dbg' | head -n1)
HDR=$(ls linux-headers-*.deb | head -n1)
[ -n "$IMG" ] && [ -n "$HDR" ] || { warn "Kernel .deb files were not produced"; exit 1; }

log "Installing $IMG and $HDR..."
apt-get install -y "./$IMG" "./$HDR"

cd /
rm -rf "$BUILD_DIR"
log "CachyOS-style kernel installed."
KB
chmod +x "$TARGET/usr/local/sbin/build-cachyos-kernel.sh"

# ---- Extra applications: Nerd Fonts, Atom, Tabby, Flatpak + Bazaar, discordo, yazi (re-runnable) ----
cat > "$TARGET/usr/local/sbin/install-extra-apps.sh" <<'APPS'
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME="${HOME:-/root}"
. /usr/local/lib/debinst-lib.sh

RUST_ADDED=0
ensure_rust() {
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    if ! command -v cargo >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
            && . "$HOME/.cargo/env" && RUST_ADDED=1
    fi
    command -v cargo >/dev/null 2>&1
}

# Chained with && on purpose: errexit is disabled inside functions called from "if".
# Install a .deb through apt. If its dependencies cannot be met on this release, repack it
# without the dependency names matching the regex in $2 and install that instead.
install_deb_relaxed() {
    local deb="$1" drop="$2" tmp rc
    if apt-get install -y "$deb"; then return 0; fi
    warn "Unmet dependencies for $(basename "$deb"); repacking without: $drop"
    tmp=$(mktemp -d) || return 1
    dpkg-deb -R "$deb" "$tmp/pkg" \
    && DROP="$drop" perl -pi -e 'if (/^Depends:\s*(.*)$/) { my @d = grep { $_ !~ /^\s*(?:$ENV{DROP})(?:[\s(|:,]|\z)/ } split(/,/, $1); $_ = "Depends: " . join(",", @d) . "\n"; }' "$tmp/pkg/DEBIAN/control" \
    && dpkg-deb -b "$tmp/pkg" "$tmp/fixed.deb" >/dev/null \
    && apt-get install -y "$tmp/fixed.deb"
    rc=$?
    rm -rf "$tmp"
    return $rc
}

# Atom was sunset by GitHub in 2022 (final release 1.60.0). Its .deb still asks for packages
# that no longer exist in Debian 13 (gconf2, gconf-service, python2, gvfs-bin).
install_atom() {
    local deb=/tmp/atom-amd64.deb rc
    curl -fL --retry 3 -o "$deb" https://github.com/atom/atom/releases/download/v1.60.0/atom-amd64.deb \
    && install_deb_relaxed "$deb" 'gconf2|gconf-service|libgconf-2-4|python|python2|gvfs-bin'
    rc=$?
    rm -f "$deb"
    return $rc
}

install_tabby() {
    local url deb=/tmp/tabby.deb rc
    url=$(curl -fsSL https://api.github.com/repos/Eugeny/tabby/releases/latest \
            | grep -o 'https://[^"]*linux-x64\.deb' | head -n1)
    [ -n "$url" ] \
    && curl -fL --retry 3 -o "$deb" "$url" \
    && apt-get install -y "$deb"
    rc=$?
    rm -f "$deb"
    return $rc
}

install_flatpak() {
    apt-get install -y --no-install-recommends flatpak \
    && try_install desktop-file-utils shared-mime-info gtk-update-icon-cache \
    && flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
}

install_bazaar() {
    command -v flatpak >/dev/null 2>&1 || return 1
    if flatpak install --system -y --noninteractive flathub io.github.kolunmi.Bazaar; then
        return 0
    fi
    # Flatpak installs can fail inside a chroot, so retry on the real system at first boot
    warn "Bazaar could not be installed here; scheduling it for first boot"
    cat > /etc/systemd/system/bazaar-firstboot.service <<'EOT'
[Unit]
Description=Install Bazaar (Flatpak) on first boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/bin/flatpak
StartLimitIntervalSec=900
StartLimitBurst=5

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak install --system -y --noninteractive flathub io.github.kolunmi.Bazaar
ExecStartPost=/bin/systemctl disable bazaar-firstboot.service
ExecStartPost=/bin/rm -f /etc/systemd/system/bazaar-firstboot.service
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOT
    systemctl enable bazaar-firstboot.service
}

install_discordo() {
    apt-get install -y golang-go git \
    && rm -rf /tmp/discordo \
    && clone_latest https://github.com/ayn2op/discordo.git /tmp/discordo \
    && ( cd /tmp/discordo && go build -o /usr/local/bin/discordo . ) \
    && rm -rf /tmp/discordo /root/go /root/.cache/go-build
}

install_yazi() {
    try_install ffmpeg 7zip jq poppler-utils fd-find ripgrep fzf zoxide imagemagick file
    ensure_rust \
    && rm -rf /tmp/yazi \
    && clone_latest https://github.com/sxyazi/yazi.git /tmp/yazi \
    && ( cd /tmp/yazi && cargo build --release --locked ) \
    && install -Dm755 /tmp/yazi/target/release/yazi /usr/local/bin/yazi \
    && install -Dm755 /tmp/yazi/target/release/ya   /usr/local/bin/ya \
    && rm -rf /tmp/yazi
}

# Nerd Fonts: archive names as published on the ryanoasis/nerd-fonts releases page.
# Override by exporting NERD_FONTS before running, e.g. NERD_FONTS="Hack Meslo".
NERD_FONTS="${NERD_FONTS:-JetBrainsMono FiraCode Hack Meslo CascadiaCode Iosevka UbuntuMono NerdFontsSymbolsOnly}"

install_nerdfonts() {
    apt-get install -y fontconfig xz-utils curl || return 1
    local dest=/usr/local/share/fonts/NerdFonts ok=0 f
    mkdir -p "$dest"
    for f in $NERD_FONTS; do
        mkdir -p "$dest/$f"
        if curl -fL --retry 3 "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$f.tar.xz" \
             | tar -xJ -C "$dest/$f"; then
            ok=$((ok + 1))
        else
            warn "Nerd font $f failed to download"
            rm -rf "$dest/$f"
        fi
    done
    fc-cache -f >/dev/null 2>&1 || true
    [ "$ok" -gt 0 ]
}

FAILED=0
for app in nerdfonts atom tabby flatpak bazaar discordo yazi; do
    log "Installing $app..."
    if ! "install_$app"; then
        warn "Failed to install $app (re-run /usr/local/sbin/install-extra-apps.sh later)"
        FAILED=1
    fi
done

if [ "$RUST_ADDED" = 1 ]; then rm -rf "$HOME/.cargo" "$HOME/.rustup"; fi
exit $FAILED
APPS
chmod +x "$TARGET/usr/local/sbin/install-extra-apps.sh"

# ---- main provisioning script ----
cat > "$TARGET/root/provision.sh" <<'PROVISION'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME=/root
. /usr/local/lib/debinst-lib.sh

# ---- APT sources and base packages ----
cat > /etc/apt/sources.list <<'EOT'
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
EOT

# Never let the GNOME desktop sneak in through "Recommends" of some other package
cat > /etc/apt/preferences.d/no-gnome <<'EOT'
Package: gnome gnome-core gnome-shell gnome-session gdm3
Pin: release *
Pin-Priority: -1
EOT

apt-get update
apt-get install -y \
    curl wget gpg ca-certificates sudo git build-essential pciutils locales tzdata \
    btrfs-progs dosfstools initramfs-tools efibootmgr \
    firmware-linux firmware-realtek firmware-misc-nonfree firmware-iwlwifi \
    openssh-server network-manager \
    dbus-user-session libpam-systemd \
    pipewire pipewire-pulse wireplumber \
    xwayland libgl1-mesa-dri mesa-vulkan-drivers \
    xdg-desktop-portal-gtk gnome-keyring libsecret-tools \
    upower power-profiles-daemon fontconfig \
    pcmanfm gvfs gvfs-backends udisks2 wl-clipboard \
    kitty fuzzel

try_install fastfetch

# ---- power management ----
# Noctalia's power profile widget uses power-profiles-daemon (profiles: performance / balanced / power-saver)
systemctl enable power-profiles-daemon.service

# ---- extra tools: monitor, audio, Qt, GTK, build tools (each skipped with a warning if unavailable) ----
try_install btop cava
try_install alsa-utils pipewire-alsa pipewire-jack
try_install qt6-base-dev qt6-declarative-dev qt6-tools-dev qt6-svg-dev qt6-wayland \
    qt6-5compat-dev qt6-qpa-plugins qt6ct qtbase5-dev qt5ct
try_install libgtk-3-dev libgtk-4-dev gtk-update-icon-cache adwaita-icon-theme
try_install cmake ninja-build

# ---- hostname, locale, timezone ----
echo "$NEW_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOT
127.0.0.1   localhost
127.0.1.1   $NEW_HOSTNAME

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOT

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

if [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
    warn "Unknown timezone '$TIMEZONE', using UTC"
    TIMEZONE=UTC
fi
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone

# ---- user ----
# No seatd: niri gets its seat through systemd-logind, so no extra group is needed.
useradd -m -G sudo,video,audio -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

if [ -n "$SSH_PUB_KEY" ]; then
    install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.ssh"
    echo "$SSH_PUB_KEY" > "/home/$USERNAME/.ssh/authorized_keys"
    chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh/authorized_keys"
fi

# ---- hardware detection ----
log "Detecting CPU/GPU..."
CPU_VENDOR=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
case "$CPU_VENDOR" in
    AuthenticAMD) apt-get install -y amd64-microcode ;;
    GenuineIntel) apt-get install -y intel-microcode ;;
esac

# Blacklist nouveau proactively (harmless without NVIDIA)
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOT'
blacklist nouveau
options nouveau modeset=0
EOT

HAS_NVIDIA=false
GPU_INFO=$(lspci | grep -Ei "VGA|3D|Display" || true)
grep -qi "NVIDIA" <<<"$GPU_INFO" && HAS_NVIDIA=true
grep -qiE "AMD|ATI" <<<"$GPU_INFO" && apt-get install -y firmware-amd-graphics
grep -qi "Intel"  <<<"$GPU_INFO" && try_install firmware-intel-graphics firmware-intel-misc

# ---- kernel command line (read by the Limine config generator) ----
mkdir -p /etc/kernel
BOOT_PARAMS="root=UUID=$ROOT_UUID rootflags=subvol=@ rw quiet"
if [ "$HAS_NVIDIA" = true ]; then
    BOOT_PARAMS="$BOOT_PARAMS nvidia-drm.modeset=1"

    cat > /etc/systemd/system/nvidia-firstboot.service <<'EOT'
[Unit]
Description=Install NVIDIA drivers on first system boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/apt-get update
ExecStart=/usr/bin/apt-get install -y nvidia-driver firmware-nvidia-gsp
ExecStartPost=/bin/systemctl disable nvidia-firstboot.service
ExecStartPost=/bin/rm -f /etc/systemd/system/nvidia-firstboot.service

[Install]
WantedBy=multi-user.target
EOT
    systemctl enable nvidia-firstboot.service
fi
echo "$BOOT_PARAMS" > /etc/kernel/cmdline

# ---- Limine ----
log "Installing Limine..."
mkdir -p /boot/EFI/BOOT

if ! apt-get install -y limine || [ ! -f /usr/share/limine/BOOTX64.EFI ]; then
    warn "limine package unavailable, using upstream binary release"
    LIMINE_BRANCH="${LIMINE_BRANCH:-v9.x-binary}"
    rm -rf /tmp/limine
    git clone --depth=1 --branch="$LIMINE_BRANCH" https://github.com/limine-bootloader/limine.git /tmp/limine
    install -Dm644 /tmp/limine/BOOTX64.EFI /usr/share/limine/BOOTX64.EFI
fi
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

# Keep the ESP copy of Limine current after package upgrades
cat > /etc/apt/apt.conf.d/99-limine-efi <<'EOT'
DPkg::Post-Invoke { "if [ -f /usr/share/limine/BOOTX64.EFI ] && mountpoint -q /boot; then mkdir -p /boot/EFI/BOOT && cp -u /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI || true; fi"; };
EOT

# Regenerates /boot/limine.conf from the kernels present in /boot
cat > /usr/local/sbin/update-limine-conf <<'EOT'
#!/bin/sh
set -e
[ -r /etc/kernel/cmdline ] || exit 0
CMDLINE=$(tr '\n' ' ' < /etc/kernel/cmdline | sed 's/ *$//')
TMP=$(mktemp)
{
    echo "timeout: 3"
    echo
    for k in $(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -rV); do
        v=${k#/boot/vmlinuz-}
        [ -f "/boot/initrd.img-$v" ] || continue
        echo "/Debian ($v)"
        echo "    protocol: linux"
        echo "    path: boot():/vmlinuz-$v"
        echo "    module_path: boot():/initrd.img-$v"
        echo "    cmdline: $CMDLINE"
        echo
    done
} > "$TMP"
cat "$TMP" > /boot/limine.conf
rm -f "$TMP"
EOT
chmod +x /usr/local/sbin/update-limine-conf

for d in postinst.d postrm.d; do
    mkdir -p "/etc/kernel/$d"
    cat > "/etc/kernel/$d/zz-update-limine" <<'EOT'
#!/bin/sh
exec /usr/local/sbin/update-limine-conf
EOT
    chmod +x "/etc/kernel/$d/zz-update-limine"
done

# ---- kernel ----
install_stock_kernel() {
    apt-get install -y linux-image-amd64 linux-headers-amd64
}

case "$KERNEL_CHOICE" in
    1)
        log "Building CachyOS-patched kernel (BORE + ThinLTO)..."
        if [ "$HAS_NVIDIA" = true ]; then
            warn "NVIDIA GPU + clang/LTO kernel: the DKMS driver build is less tested on this combination."
            warn "If the nvidia driver fails after first boot, boot the fallback kernel or rebuild with kernel option 2/3."
        fi
        if bash /usr/local/sbin/build-cachyos-kernel.sh "$XLEVEL"; then
            log "CachyOS-style kernel installed."
        else
            warn "Kernel build failed, installing the Debian stock kernel so the system still boots."
            warn "Retry later with: sudo /usr/local/sbin/build-cachyos-kernel.sh $XLEVEL"
            install_stock_kernel
        fi
        ;;
    2)
        log "Installing XanMod kernel ($XANMOD_PKG)..."
        mkdir -p /etc/apt/keyrings
        if wget -qO- https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg \
           && echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org/ releases main' \
                > /etc/apt/sources.list.d/xanmod-release.list \
           && apt-get update \
           && apt-get install -y "$XANMOD_PKG"; then
            log "XanMod kernel installed."
        else
            warn "XanMod install failed, falling back to the Debian kernel"
            rm -f /etc/apt/sources.list.d/xanmod-release.list
            apt-get update
            install_stock_kernel
        fi
        ;;
    *)
        install_stock_kernel
        ;;
esac

# Make sure initrds are current, then (re)generate the Limine config
update-initramfs -u -k all
/usr/local/sbin/update-limine-conf
grep -q '^/Debian' /boot/limine.conf || { warn "No boot entry was generated in /boot/limine.conf"; exit 1; }
ls /boot/EFI/BOOT/BOOTX64.EFI >/dev/null

# ---- Niri (+ xwayland-satellite) ----
# Preferred: prebuilt packages from the DankLinux OBS repo for Debian 13. (The matching
# Ubuntu PPAs cannot be used on Debian.) Fallback: build from source.
write_dank_pins() {
    cat > /etc/apt/preferences.d/danklinux <<'EOT'
# Trust the DankLinux repo only for niri and xwayland-satellite, nothing else.
Package: *
Pin: origin download.opensuse.org
Pin-Priority: 1

Package: niri xwayland-satellite
Pin: origin download.opensuse.org
Pin-Priority: 600
EOT
}

install_niri_from_repo() {
    local base="https://download.opensuse.org/repositories/home:/AvengeMedia:/danklinux/Debian_13"
    mkdir -p /etc/apt/keyrings \
    && curl -fsSL "$base/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/danklinux.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/danklinux.gpg] $base/ /" > /etc/apt/sources.list.d/danklinux.list \
    && write_dank_pins \
    && apt-get update \
    && apt-get install -y --no-install-recommends niri
}

build_niri_from_source() {
    log "Installing build dependencies..."
    apt-get install -y \
        clang libclang-dev pkg-config libssl-dev libudev-dev libgbm-dev libxkbcommon-dev \
        libegl1-mesa-dev libwayland-dev libinput-dev libdbus-1-dev libsystemd-dev \
        libseat-dev libpipewire-0.3-dev libpango1.0-dev libglib2.0-dev \
        libdisplay-info-dev libxcb-cursor-dev

    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    . "$HOME/.cargo/env"
    cargo install cargo-deb --locked

    log "Building xwayland-satellite..."
    rm -rf /tmp/xwayland-satellite
    clone_latest https://github.com/Supreeeme/xwayland-satellite.git /tmp/xwayland-satellite
    ( cd /tmp/xwayland-satellite && cargo install --locked --path . --root /usr/local )

    log "Building niri..."
    rm -rf /tmp/niri
    clone_latest https://github.com/niri-wm/niri.git /tmp/niri
    cd /tmp/niri
    if cargo deb && apt-get install -y --no-install-recommends ./target/debian/niri_*.deb; then
        log "niri installed from .deb"
    else
        warn "cargo deb route failed, installing niri manually"
        cargo install --locked --path . --root /usr/local
        install -Dm755 resources/niri-session /usr/local/bin/niri-session
        install -Dm644 resources/niri.desktop /usr/share/wayland-sessions/niri.desktop
        install -Dm644 resources/niri-portals.conf /usr/share/xdg-desktop-portal/niri-portals.conf
        install -Dm644 resources/niri-shutdown.target /etc/systemd/user/niri-shutdown.target
        sed 's|/usr/bin|/usr/local/bin|g' resources/niri.service > /etc/systemd/user/niri.service
    fi
    cd /
}

if install_niri_from_repo; then
    log "niri installed from the DankLinux repo"
else
    warn "Could not install niri from the DankLinux repo, building from source instead (slow)"
    rm -f /etc/apt/sources.list.d/danklinux.list /etc/apt/preferences.d/danklinux /etc/apt/keyrings/danklinux.gpg
    apt-get update
    build_niri_from_source
fi

command -v niri >/dev/null 2>&1 || { warn "niri is not installed"; exit 1; }
command -v niri-session >/dev/null 2>&1 || warn "niri-session not found in PATH (login manager may not start the session)"
command -v xwayland-satellite >/dev/null 2>&1 || warn "xwayland-satellite not found; X11 apps will not work until it is installed"

# Locate niri's default config (package doc dir, source tree, or upstream at the same version)
find_default_niri_config() {
    local f ver ref
    for f in /tmp/niri/resources/default-config.kdl \
             /usr/share/doc/niri/default-config.kdl \
             /usr/share/niri/default-config.kdl; do
        if [ -f "$f" ]; then echo "$f"; return 0; fi
    done
    f=$(dpkg -L niri 2>/dev/null | grep -m1 'default-config.kdl' || true)
    if [ -n "$f" ] && [ -f "$f" ]; then echo "$f"; return 0; fi
    ver=$(niri --version 2>/dev/null | awk '{print $2}')
    for ref in "v$ver" "main"; do
        [ "$ref" = "v" ] && continue   # version lookup failed
        curl -fsSL "https://raw.githubusercontent.com/niri-wm/niri/$ref/resources/default-config.kdl" \
            -o /tmp/niri-default-config.kdl || continue
        # The version-matched file is trusted. "main" may be newer than the installed niri,
        # so only use it if niri accepts it.
        if [ "$ref" = "main" ] && ! niri validate -c /tmp/niri-default-config.kdl >/dev/null 2>&1; then
            rm -f /tmp/niri-default-config.kdl
            continue
        fi
        echo /tmp/niri-default-config.kdl
        return 0
    done
    return 0
}

# ---- login manager: greetd + tuigreet (no GNOME/Qt/GTK pulled in) ----
LOGIN_MODE=tty
if [ "$LOGIN_CHOICE" != "3" ]; then
    if apt-get install -y greetd tuigreet; then
        if   id _greetd >/dev/null 2>&1; then GREETER_USER=_greetd
        elif id greeter >/dev/null 2>&1; then GREETER_USER=greeter
        else
            useradd --system --no-create-home --shell /usr/sbin/nologin -G video greeter
            GREETER_USER=greeter
        fi

        mkdir -p /etc/greetd
        cat > /etc/greetd/config.toml <<EOT
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --greeting 'Welcome back' --theme 'border=lightblue;text=white;prompt=lightcyan;time=lightmagenta;action=lightblue;button=lightcyan;container=black;input=white' --cmd niri-session"
user = "$GREETER_USER"
EOT

        # tuigreet stores the last user/session here
        install -d -m 0755 -o "$GREETER_USER" -g "$(id -gn "$GREETER_USER")" /var/cache/tuigreet
        # greetd uses tty1; getty must not share it, or the two compete for every keystroke
        mkdir -p /etc/systemd/system/greetd.service.d
        cat > /etc/systemd/system/greetd.service.d/10-no-getty.conf <<'EOT'
[Unit]
Conflicts=getty@tty1.service
After=getty@tty1.service
EOT
        systemctl disable getty@tty1.service || true
        systemctl enable greetd.service
        LOGIN_MODE=greetd
        log "greetd + tuigreet configured (greeter user: $GREETER_USER)"
    else
        warn "greetd/tuigreet could not be installed, falling back to tty1 autostart"
    fi
fi

# ---- user session config ----
UHOME="/home/$USERNAME"
install -d -o "$USERNAME" -g "$USERNAME" "$UHOME/.config/niri"
NIRI_DEFAULT_CFG=$(find_default_niri_config)
if [ -n "$NIRI_DEFAULT_CFG" ]; then
    install -m 644 -o "$USERNAME" -g "$USERNAME" "$NIRI_DEFAULT_CFG" "$UHOME/.config/niri/config.kdl"
else
    warn "No default niri config found; niri will use its built-in defaults until you create ~/.config/niri/config.kdl."
fi

# Start niri automatically on tty1 (no display manager needed)
echo '[ -f "$HOME/.profile" ] && . "$HOME/.profile"' > "$UHOME/.bash_profile"
if [ "$LOGIN_MODE" = "tty" ]; then
    # No login manager: start niri automatically on tty1
    cat >> "$UHOME/.bash_profile" <<'EOT'
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec niri-session
fi
EOT
fi
chown "$USERNAME:$USERNAME" "$UHOME/.bash_profile"

# ---- Kitty as the default terminal ----
# 1) system-wide x-terminal-emulator alternative
update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/kitty 60 || true
update-alternatives --set x-terminal-emulator /usr/bin/kitty || warn "Could not set x-terminal-emulator"

# 2) session environment and launcher: apps that honor $TERMINAL, and fuzzel's terminal apps
echo "TERMINAL=kitty" >> /etc/environment
install -d -o "$USERNAME" -g "$USERNAME" "$UHOME/.config/fuzzel" "$UHOME/.config/kitty"
cat > "$UHOME/.config/fuzzel/fuzzel.ini" <<'EOT'
[main]
terminal=kitty
EOT

# 3) Kitty config using a Nerd Font (installed by install-extra-apps.sh)
cat > "$UHOME/.config/kitty/kitty.conf" <<'EOT'
font_family             JetBrainsMono Nerd Font Mono
font_size               11.0
window_padding_width    6
confirm_os_window_close 0
EOT
chown -R "$USERNAME:$USERNAME" "$UHOME/.config/fuzzel" "$UHOME/.config/kitty"

# 4) niri's default config launches alacritty with Mod+T; point it at kitty
if [ -f "$UHOME/.config/niri/config.kdl" ]; then
    sed -i 's/alacritty/kitty/g' "$UHOME/.config/niri/config.kdl"
fi

# ---- Noctalia (non-fatal) ----
if ! bash /usr/local/sbin/install-noctalia.sh "$USERNAME"; then
    warn "Noctalia install failed. Niri will still work."
    warn "After first boot, retry with: sudo /usr/local/sbin/install-noctalia.sh $USERNAME"
fi

# ---- Noctalia Greeter (needs the Noctalia APT repo; falls back to the tuigreet config above) ----
if [ "$LOGIN_MODE" = "greetd" ] && [ "$LOGIN_CHOICE" = "1" ]; then
    if apt-get install -y noctalia-greeter && NG_SESSION=$(command -v noctalia-greeter-session); then
        try_install accountsservice polkitd
        usermod -aG video,input "$GREETER_USER" || true
        install -d -o "$GREETER_USER" -g "$(id -gn "$GREETER_USER")" /var/lib/noctalia-greeter
        cp /etc/greetd/config.toml /etc/greetd/config.toml.tuigreet
        cat > /etc/greetd/config.toml <<EOT
[terminal]
vt = 1

[default_session]
command = "$NG_SESSION"
user = "$GREETER_USER"
EOT
        log "Noctalia Greeter configured (the previous tuigreet config is in /etc/greetd/config.toml.tuigreet)"
    else
        warn "noctalia-greeter is not available, keeping tuigreet as the login screen"
    fi
fi

# ---- Nerd Fonts, Atom, Tabby, Flatpak + Bazaar, discordo, yazi (non-fatal) ----
if ! bash /usr/local/sbin/install-extra-apps.sh; then
    warn "Some extra apps failed. Retry after first boot with: sudo /usr/local/sbin/install-extra-apps.sh"
fi

# Launcher entries for the terminal apps (so fuzzel can find them)
cat > /usr/share/applications/yazi.desktop <<'EOT'
[Desktop Entry]
Name=Yazi
Comment=Terminal file manager
Exec=kitty yazi
Icon=system-file-manager
Terminal=false
Type=Application
Categories=System;FileTools;FileManager;ConsoleOnly;
EOT
cat > /usr/share/applications/discordo.desktop <<'EOT'
[Desktop Entry]
Name=Discordo
Comment=Discord terminal client
Exec=kitty discordo
Icon=internet-chat
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
EOT

# ---- services ----
systemctl enable ssh NetworkManager
systemctl enable upower || true   # D-Bus activated anyway

# ---- cleanup ----
apt-get clean
rm -rf /tmp/* /root/.cargo /root/.rustup /root/provision.sh
PROVISION

# ---------------------------------------------------------------
# 8. Run provisioning inside the chroot
# ---------------------------------------------------------------
log "Entering chroot..."
chroot "$TARGET" /usr/bin/env \
    USERNAME="$USERNAME" \
    USER_PASSWORD="$USER_PASSWORD" \
    NEW_HOSTNAME="$NEW_HOSTNAME" \
    TIMEZONE="$TIMEZONE" \
    SSH_PUB_KEY="$SSH_PUB_KEY" \
    ROOT_UUID="$ROOT_UUID" \
    KERNEL_CHOICE="$KERNEL_CHOICE" \
    XANMOD_PKG="$XANMOD_PKG" \
    XLEVEL="$XLEVEL" \
    LOGIN_CHOICE="$LOGIN_CHOICE" \
    /bin/bash /root/provision.sh

sync
log "Deployment complete. Unmounting target drives..."
umount -R "$TARGET"
trap - EXIT
echo "[+] Done! Remove the live USB and reboot."
if [ "$LOGIN_CHOICE" != "3" ]; then
    echo "    After reboot the greetd login screen appears; log in as '$USERNAME' and niri starts."
    echo "    (If greetd failed to install, log in on tty1 instead; niri autostarts there.)"
else
    echo "    Log in on tty1 as '$USERNAME'; niri starts automatically."
fi
