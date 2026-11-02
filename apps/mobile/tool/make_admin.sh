#!/usr/bin/env bash
# Turns the generated Android project into the separate "GM Admin" app (super admin only):
# its own app id (so both apps can be installed), name and crown icon.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in android/app/build.gradle android/app/build.gradle.kts; do
  if [ -f "$f" ]; then sed -i 's/applicationId\(\s*=\?\s*\)"com\.gymmantra\.gymmantra"/applicationId\1"com.gymmantra.admin"/' "$f"; grep -n applicationId "$f"; fi
done
sed -i 's#android:label="[^"]*"#android:label="GM Admin"#' android/app/src/main/AndroidManifest.xml
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  cp "assets/icon_admin/mipmap-$d.png" "android/app/src/main/res/mipmap-$d/ic_launcher.png"
done
