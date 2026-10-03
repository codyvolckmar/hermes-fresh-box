#!/usr/bin/env bash
# =============================================================================
# hermes-fresh-box.sh — one-shot Hermes Agent bootstrap for a FRESH Linux box
# =============================================================================
# Pre-installs every OS-level package Hermes needs (base build tools, Python,
# search/media, Playwright/Chromium runtime libs, X11 desktop-automation libs
# for the Computer Use toolset, secret storage, headless/VNC, voice, monitoring)
# and then runs Nous Research's official installer:
#
#     curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
#
# The official installer is the source of truth for Hermes itself (uv, managed
# Python 3.11, git, managed Node, ripgrep/ffmpeg best-effort, browser-use CLI,
# Playwright Chromium, cua-driver, config templates). This script only removes
# the friction *before* it: apt/dnf/pacman is fully populated so the installer
# never has to prompt for sudo, never silently skips ripgrep/ffmpeg, and never
# falls back to "install Chromium deps manually".
#
# Design rules:
#   - Idempotent. Safe to re-run on a half-built box; only missing packages are
#     installed, and each group install is skipped when already satisfied.
#   - Never aborts the whole run because one optional package is unavailable
#     (name transitions like libasound2 -> libasound2t64 are handled by probing
#     the repo instead of guessing).
#   - Non-interactive by default for the package phase; the Hermes setup wizard
#     still runs interactively unless you pass --auto.
#
# Usage:
#   chmod +x hermes-fresh-box.sh
#   ./hermes-fresh-box.sh                 # full install, interactive setup wizard
#   ./hermes-fresh-box.sh --auto          # unattended (skips the setup wizard)
#   ./hermes-fresh-box.sh --minimal       # base + python + search + browser only
#   ./hermes-fresh-box.sh --headless      # add Xvfb + x11vnc (VNC survives reboot)
#   ./hermes-fresh-box.sh --include-desktop   # also build the Electron desktop app
#   ./hermes-fresh-box.sh --no-packages   # skip OS packages, just run installer
#   ./hermes-fresh-box.sh --dry-run       # show what would be installed
#   ./hermes-fresh-box.sh -- --skip-browser --no-skills   # pass through to installer
# =============================================================================
set -euo pipefail

HERMES_INSTALLER_URL="${HERMES_INSTALLER_URL:-https://hermes-agent.nousresearch.com/install.sh}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LOG_FILE="${LOG_FILE:-$HOME/hermes-fresh-box.log}"

# ---- ANSI (disabled when not a tty) ----------------------------------------
if [ -t 1 ]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; B=$'\033[0;34m'
  C=$'\033[0;36m'; M=$'\033[0;35m'; BD=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; C=""; M=""; BD=""; N=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s→%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s⚠%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; }

# ---- Options ----------------------------------------------------------------
MINIMAL=false
WITH_HEADLESS=false
INCLUDE_DESKTOP=false
NO_PACKAGES=false
DRY_RUN=false
AUTO=false
INSTALLER_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --minimal)         MINIMAL=true; shift ;;
    --headless)        WITH_HEADLESS=true; shift ;;
    --include-desktop) INCLUDE_DESKTOP=true; shift ;;
    --no-packages)     NO_PACKAGES=true; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
    --auto|--yes|-y)   AUTO=true; shift ;;
    --hermes-home)     HERMES_HOME="$2"; shift 2 ;;
    --url)             HERMES_INSTALLER_URL="$2"; shift 2 ;;
    --)                shift; INSTALLER_ARGS=("$@"); break ;;
    -h|--help)
      sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "Unknown option: $1 (use --help)"; exit 2 ;;
  esac
done
export HERMES_HOME

# ---- sudo / root ------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    err "Not root and no sudo found — cannot install system packages."
    exit 1
  fi
fi

# ---- Package manager --------------------------------------------------------
detect_pkg_mgr() {
  if   command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG_MGR=dnf
  elif command -v pacman  >/dev/null 2>&1; then PKG_MGR=pacman
  elif command -v zypper  >/dev/null 2>&1; then PKG_MGR=zypper
  elif command -v apk     >/dev/null 2>&1; then PKG_MGR=apk
  else PKG_MGR=none; fi
}

# Print the package names for one group, per distro family.
# Ubuntu 24.04+/Mint libasound2 -> libasound2t64 transitions are handled by
# listing both and letting the apt availability probe drop the dead one.
group_pkgs() {
  local g="$1"
  case "$PKG_MGR:$g" in
    # ------------------------------- apt ----------------------------------
    apt:base)        echo "curl ca-certificates gnupg git build-essential pkg-config make unzip zip xz-utils tar rsync jq tmux screen less nano wget" ;;
    apt:python)      echo "python3 python3-venv python3-dev python3-pip python3-setuptools libffi-dev" ;;
    apt:search)      echo "ripgrep fd-find fzf" ;;
    apt:media)       echo "ffmpeg imagemagick" ;;
    apt:browser)     echo "libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 libasound2t64 libatspi2.0-0 libx11-xcb1 libxcb-dri3-0 libxshmfence1 libxss1 libu2f-udev libvulkan1 fonts-liberation fonts-noto-color-emoji xdg-utils" ;;
    apt:computer-use) echo "xdotool wmctrl x11-utils x11-xserver-utils xauth xclip scrot dbus-x11 libnotify-bin at-spi2-core xdg-utils" ;;
    apt:secrets)     echo "gnome-keyring libsecret-1-0 libsecret-tools" ;;
    apt:headless)    echo "xvfb x11vnc openbox xterm" ;;
    apt:desktop-build) echo "libgtk-3-0 libnotify4 libxtst6 libnss3 libgbm1 libasound2 libasound2t64 rpm fakeroot dpkg" ;;
    apt:voice)       echo "portaudio19-dev libportaudio2 espeak-ng sox" ;;
    apt:monitoring)  echo "htop procps psmisc lsof net-tools iproute2 tree ncdu" ;;
    # ------------------------------- dnf ----------------------------------
    dnf:base)        echo "curl ca-certificates gnupg2 git @development-tools pkgconf-pkg-config make unzip zip xz tar rsync jq tmux screen less nano wget" ;;
    dnf:python)      echo "python3 python3-devel python3-pip libffi-devel" ;;
    dnf:search)      echo "ripgrep fd-find fzf" ;;
    dnf:media)       echo "ffmpeg ImageMagick" ;;
    dnf:browser)     echo "nss nspr atk at-spi2-atk cups-libs libdrm libxkbcommon libXcomposite libXdamage libXfixes libXrandr mesa-libgbm pango cairo alsa-lib at-spi2-core libX11-xcb libxcb libxshmfence libXScrnSaver vulkan-loader liberation-fonts google-noto-emoji-fonts xdg-utils" ;;
    dnf:computer-use) echo "xdotool wmctrl xorg-x11-utils xorg-x11-xauth xclip scrot dbus-x11 libnotify at-spi2-core xdg-utils" ;;
    dnf:secrets)     echo "gnome-keyring libsecret" ;;
    dnf:headless)    echo "xorg-x11-server-Xvfb x11vnc openbox xterm" ;;
    dnf:desktop-build) echo "gtk3 libnotify libXtst nss mesa-libgbm alsa-lib rpm-build fakeroot" ;;
    dnf:voice)       echo "portaudio portaudio-devel espeak-ng sox" ;;
    dnf:monitoring)  echo "htop procps-ng psmisc lsof net-tools iproute tree ncdu" ;;
    # ------------------------------ pacman --------------------------------
    pacman:base)     echo "curl ca-certificates gnupg git base-devel make unzip zip xz tar rsync jq tmux screen less nano wget" ;;
    pacman:python)   echo "python python-pip" ;;
    pacman:search)   echo "ripgrep fd fzf" ;;
    pacman:media)    echo "ffmpeg imagemagick" ;;
    pacman:browser)  echo "nss atk at-spi2-atk cups libdrm libxkbcommon libxcomposite libxdamage libxfixes libxrandr mesa gtk3 pango cairo alsa-lib at-spi2-core libx11 libxcb libxshmfence libxss vulkan-icd-loader ttf-liberation noto-fonts-emoji xdg-utils" ;;
    pacman:computer-use) echo "xdotool wmctrl xorg-xrandr xorg-xwininfo xclip scrot dbus libnotify at-spi2-core xdg-utils" ;;
    pacman:secrets)  echo "gnome-keyring libsecret" ;;
    pacman:headless) echo "xorg-server-xvfb x11vnc openbox xterm" ;;
    pacman:desktop-build) echo "gtk3 libnotify libxtst nss mesa alsa-lib rpm fakeroot" ;;
    pacman:voice)    echo "portaudio espeak-ng sox" ;;
    pacman:monitoring) echo "htop procps-ng psmisc lsof net-tools iproute2 tree ncdu" ;;
    # ------------------------- zypper (best effort) -----------------------
    zypper:*)        echo "" ;;
    apk:*)           echo "" ;;
    *)               echo "" ;;
  esac
}

# Is this package available in the configured apt repos?
apt_available() { apt-cache show "$1" >/dev/null 2>&1; }
# Is this package already installed? (no grep -q in a pipe: SIGPIPE + pipefail
# would abort the run on a successful match)
apt_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  case "$st" in *"install ok installed"*) return 0 ;; *) return 1 ;; esac
}

apt_update_once() {
  [ "${_APT_UPDATED:-false}" = true ] && return 0
  info "apt-get update"
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -qq || warn "apt-get update reported errors (continuing)"
  _APT_UPDATED=true
}

install_group() {
  local name="$1"
  local -a want=()
  read -r -a want <<<"$(group_pkgs "$name")"
  [ "${#want[@]}" -eq 0 ] && return 0

  case "$PKG_MGR" in
    apt)
      local -a todo=()
      local p
      for p in "${want[@]}"; do
        apt_installed "$p" && continue
        if apt_available "$p"; then
          todo+=("$p")
        else
          warn "[$name] '$p' not in repos on this distro — skipping"
        fi
      done
      if [ "${#todo[@]}" -eq 0 ]; then
        ok "[$name] already satisfied"
        return 0
      fi
      if [ "$DRY_RUN" = true ]; then
        say "  ${BD}[$name]${N} would apt-get install: ${todo[*]}"
        return 0
      fi
      apt_update_once
      info "[$name] installing ${#todo[@]} package(s)"
      if $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
           apt-get install -y -qq --no-install-recommends "${todo[@]}"; then
        ok "[$name] installed"
      else
        warn "[$name] some packages failed; retrying without --no-install-recommends"
        $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
          apt-get install -y -qq "${todo[@]}" || warn "[$name] install had errors (continuing)"
      fi
      ;;
    dnf)
      if [ "$DRY_RUN" = true ]; then say "  ${BD}[$name]${N} would dnf install: ${want[*]}"; return 0; fi
      info "[$name] dnf install (--skip-broken)"
      $SUDO dnf install -y --skip-broken --setopt=install_weak_deps=False "${want[@]}" \
        || warn "[$name] dnf install had errors (continuing)"
      ;;
    pacman)
      if [ "$DRY_RUN" = true ]; then say "  ${BD}[$name]${N} would pacman -S: ${want[*]}"; return 0; fi
      info "[$name] pacman install"
      local p
      for p in "${want[@]}"; do
        pacman -Qq "$p" >/dev/null 2>&1 && continue
        $SUDO pacman -S --needed --noconfirm "$p" || warn "[$name] '$p' failed (continuing)"
      done
      ;;
    zypper)
      if [ "$DRY_RUN" = true ]; then say "  ${BD}[$name]${N} would zypper install: ${want[*]}"; return 0; fi
      $SUDO zypper --non-interactive install -y "${want[@]}" || warn "[$name] zypper install had errors (continuing)"
      ;;
    none)
      warn "No supported package manager found — install OS packages by hand."
      return 0
      ;;
  esac
}

# ---- Pre-flight -------------------------------------------------------------
preflight() {
  say ""
  printf '%s%s' "$M" "$BD"
  cat <<'BANNER'
┌──────────────────────────────────────────────────────────┐
│  Hermes Agent — fresh-box bootstrap                      │
│  OS packages first, then the official installer.         │
└──────────────────────────────────────────────────────────┘
BANNER
  printf '%s' "$N"
  say ""
  info "Log: $LOG_FILE"
  if command -v curl >/dev/null 2>&1; then
    ok "curl present"
  else
    warn "curl missing — will be installed with the base group"
  fi
  case "$(uname -s)" in
    Linux*) : ;;
    Darwin*) err "This script targets Linux. macOS: use the official installer (brew provides deps)."; exit 1 ;;
    *) err "Unsupported OS: $(uname -s)"; exit 1 ;;
  esac
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "Distro: ${PRETTY_NAME:-$ID}"
  fi
  info "User: $(id -un) (uid $(id -u)) — sudo: ${SUDO:-<root>}"
}

# ---- Hermes itself ----------------------------------------------------------
run_hermes_installer() {
  say ""
  info "Running the official Hermes installer"
  local args=()
  if [ "$AUTO" = true ]; then
    args+=(--non-interactive --skip-setup)
  fi
  if [ "$INCLUDE_DESKTOP" = true ]; then
    args+=(--include-desktop)
  fi
  if [ "${#INSTALLER_ARGS[@]}" -gt 0 ]; then
    args+=("${INSTALLER_ARGS[@]}")
  fi

  if [ "$DRY_RUN" = true ]; then
    say "  would: curl -fsSL $HERMES_INSTALLER_URL | bash -s -- ${args[*]:-}"
    return 0
  fi

  # Download first, then run: piping straight into bash masks curl failures
  # (bash exits 0 on empty stdin) and conflates network errors with installer
  # errors. Same two-stage approach the installer uses for uv.
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/hermes-install.XXXXXX.sh")"
  if ! curl -fsSL "$HERMES_INSTALLER_URL" -o "$tmp"; then
    err "Could not download $HERMES_INSTALLER_URL"
    rm -f "$tmp"
    exit 1
  fi
  local sig
  sig="$(head -c 200 "$tmp" 2>/dev/null || true)"
  case "$sig" in
    *Hermes*) : ;;
    *) warn "Downloaded installer does not look like the Hermes script — aborting"; rm -f "$tmp"; exit 1 ;;
  esac
  ok "Installer downloaded ($(wc -c <"$tmp") bytes)"
  # -s -- makes the piped-usage contract explicit and lets install.sh parse args.
  bash -s -- "${args[@]}" <"$tmp" || { local rc=$?; rm -f "$tmp"; err "Installer exited $rc"; exit "$rc"; }
  rm -f "$tmp"
  ok "Official installer finished"
}

ensure_path() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
  # Make it stick for future logins.
  local rcfile="$HOME/.bashrc"
  [ -n "${ZSH_VERSION:-}" ] && rcfile="$HOME/.zshrc"
  if [ -f "$rcfile" ] && ! grep -q '\.local/bin' "$rcfile" 2>/dev/null; then
    printf '\n# Added by hermes-fresh-box.sh\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$rcfile"
    info "Added ~/.local/bin to PATH in $rcfile"
  fi
}

verify() {
  say ""
  say "${BD}Verification${N}"
  local hb
  hb="$(command -v hermes 2>/dev/null || true)"
  if [ -n "$hb" ]; then ok "hermes → $hb"; else warn "hermes not on PATH (open a new shell or check the installer output)"; fi

  local t vercmd verout
  for t in git rg ffmpeg node npm python3 uv xdotool wmctrl xvfb-run x11vnc sqlite3 tmux; do
    if command -v "$t" >/dev/null 2>&1; then
      vercmd="--version"; [ "$t" = ffmpeg ] && vercmd="-version"
      verout="$("$t" "$vercmd" 2>/dev/null || true)"
      verout="$(printf '%s\n' "$verout" | head -1 | cut -c1-60)"
      printf '  %s✓%s %-9s %s\n' "$G" "$N" "$t" "$verout"
    else
      printf '  %s·%s %-9s %s\n' "$Y" "$N" "$t" "not found"
    fi
  done

  if command -v hermes >/dev/null 2>&1 && [ "$DRY_RUN" = false ]; then
    say ""
    info "hermes doctor"
    hermes doctor 2>&1 | tee -a "$LOG_FILE" || warn "hermes doctor reported issues (see above)"
  fi
}

main() {
  preflight
  detect_pkg_mgr
  info "Package manager: $PKG_MGR"

  if [ "$NO_PACKAGES" = false ] && [ "$PKG_MGR" != none ]; then
    say ""
    say "${BD}System packages${N}"
    if [ "$MINIMAL" = true ]; then
      group_list=("base" "python" "search" "browser")
      info "Minimal mode: base + python + search + browser groups only"
    else
      group_list=("base" "python" "search" "media" "browser" "computer-use" "secrets" "monitoring" "voice")
    fi
    local g
    for g in "${group_list[@]}"; do install_group "$g"; done
    if [ "$WITH_HEADLESS" = true ]; then install_group headless; else info "Skipping headless group (pass --headless for Xvfb + x11vnc)"; fi
    if [ "$INCLUDE_DESKTOP" = true ]; then install_group desktop-build; else info "Skipping desktop-build group (pass --include-desktop)"; fi
  elif [ "$NO_PACKAGES" = true ]; then
    info "Skipping OS packages (--no-packages)"
  fi

  run_hermes_installer
  ensure_path
  verify

  say ""
  ok "Done."
  say "  Next:  ${BD}hermes setup${N}   (model + provider), then ${BD}hermes${N} to chat"
  say "         ${BD}hermes doctor${N}  to re-check the environment"
}

main 2>&1 | tee -a "$LOG_FILE"
