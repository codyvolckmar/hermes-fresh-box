# hermes-fresh-box
# hermes-fresh-box.sh — one-shot Hermes Agent bootstrap for a FRESH Linux box
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
