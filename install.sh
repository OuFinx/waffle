#!/bin/sh
# Builds Waffle from source on this Mac and puts it in /Applications. Run it again any time to update (after `git pull`).
# Needs: a Mac with Apple Silicon, macOS 15 or newer and the Xcode Command Line Tools. Everything else it sets up itself.
set -e
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m%s\033[0m\n" "$1"; exit 1; }

bold "Waffle: checking this Mac"
[ "$(uname -m)" = arm64 ] || fail "Waffle needs a Mac with Apple Silicon (M1 or newer)."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ] || fail "Waffle needs macOS 15 Sequoia or newer."
xcode-select -p >/dev/null 2>&1 || { xcode-select --install; fail "Install the Command Line Tools in the window that opened, then run ./install.sh again."; }
# A local signing certificate keeps the Microphone and System Audio permissions across updates. Free, and it never leaves this Mac.
bold "Setting up local code signing"
./make-signing-identity.sh

bold "Building Waffle (a few minutes the first time)"
./build.sh

bold "Done. Opening Waffle."
echo "The first launch walks you through the speech models download, permissions and the AI for summaries."
open /Applications/Waffle.app
