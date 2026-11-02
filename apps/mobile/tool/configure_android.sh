#!/usr/bin/env bash
# Applies GymMantra settings to the generated Android project. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."
M=android/app/src/main/AndroidManifest.xml
grep -q 'android.permission.INTERNET' "$M" || sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$M"
sed -i 's#android:label="[^"]*"#android:label="GymMantra"#' "$M"
# Photo cropper screen (image_cropper / uCrop)
grep -q 'UCropActivity' "$M" || sed -i 's#</application>#    <activity android:name="com.yalantis.ucrop.UCropActivity" android:screenOrientation="portrait" android:theme="@style/Theme.AppCompat.Light.NoActionBar"/>\n    </application>#' "$M"
# App icon (logo C: dumbbell + heartbeat)
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  cp "assets/icon/mipmap-$d.png" "android/app/src/main/res/mipmap-$d/ic_launcher.png"
done
# Dark launch background so the app never flashes white before the animated splash
for f in android/app/src/main/res/drawable/launch_background.xml android/app/src/main/res/drawable-v21/launch_background.xml; do
  [ -f "$f" ] && cat > "$f" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item><color android:color="#0D1015"/></item>
</layer-list>
XML
done
grep -n 'INTERNET\|android:label\|UCrop' "$M"
