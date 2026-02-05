#!/usr/bin/env bash
set -euo pipefail

APPS=(
  "/Applications/LocalTranslator.app"
  "/Applications/TranslatorHotkey.app"
)

FILES=(
  "$HOME/Library/Preferences/com.example.LocalTranslator.plist"
  "$HOME/Library/Preferences/com.example.TranslatorHotkey.plist"
  "$HOME/Library/Application Support/LocalTranslator"
  "$HOME/Library/Application Support/TranslatorHotkey"
  "$HOME/Library/Caches/com.example.LocalTranslator"
  "$HOME/Library/Caches/com.example.TranslatorHotkey"
)

echo "Removing old apps (if present):"
for app in "${APPS[@]}"; do
  if [ -e "$app" ]; then
    echo "  - $app"
    rm -rf "$app"
  fi
done

echo "Removing old preferences/cache (if present):"
for path in "${FILES[@]}"; do
  if [ -e "$path" ]; then
    echo "  - $path"
    rm -rf "$path"
  fi
done

echo "Done."
