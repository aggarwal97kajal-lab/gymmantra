#!/usr/bin/env bash
# Applies GymMantra settings to the generated Android project. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."
M=android/app/src/main/AndroidManifest.xml
grep -q 'android.permission.INTERNET' "$M" || sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$M"
sed -i 's#android:label="[^"]*"#android:label="GymMantra"#' "$M"
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  cp "../../brand/android/mipmap-$d/ic_launcher.png" "android/app/src/main/res/mipmap-$d/ic_launcher.png"
done
grep -n 'INTERNET\|android:label' "$M"
