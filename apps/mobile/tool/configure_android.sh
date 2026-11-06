#!/usr/bin/env bash
# Applies GymMantra settings to the generated Android project. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."
M=android/app/src/main/AndroidManifest.xml
grep -q 'android.permission.INTERNET' "$M" || sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$M"
sed -i 's#android:label="[^"]*"#android:label="GymMantra"#' "$M"
# Location (gym check-in near the gym) and saving the QR poster on old Android versions
for perm in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION CAMERA; do
  grep -q "android.permission.$perm\"" "$M" || sed -i "s#<application#<uses-permission android:name=\"android.permission.$perm\"/>\n    <application#" "$M"
done
grep -q 'WRITE_EXTERNAL_STORAGE' "$M" || sed -i 's#<application#<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>\n    <application#' "$M"
# Smaller Gradle memory so two builds in one job don't run the machine out of memory
GP=android/gradle.properties
if [ -f "$GP" ]; then
  sed -i 's/^org.gradle.jvmargs=.*/org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=1G -XX:+HeapDumpOnOutOfMemoryError/' "$GP"
  grep -q '^kotlin.daemon.jvmargs' "$GP" || echo 'kotlin.daemon.jvmargs=-Xmx2G' >> "$GP"
fi
# Reports saved straight into the phone's Download folder (Android 10 needs legacy storage)
grep -q 'requestLegacyExternalStorage' "$M" || sed -i 's#<application#<application android:requestLegacyExternalStorage="true"#' "$M"
# UPI apps (GPay, PhonePe, Paytm, BHIM…) for paying the GymMantra plan
if ! grep -q 'android:scheme="upi"' "$M"; then
  if grep -q '</queries>' "$M"; then
    sed -i 's#</queries>#    <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="upi"/></intent>\n        <package android:name="com.google.android.apps.nbu.paisa.user"/>\n        <package android:name="com.phonepe.app"/>\n        <package android:name="net.one97.paytm"/>\n        <package android:name="in.org.npci.upiapp"/>\n    </queries>#' "$M"
  else
    sed -i 's#</manifest>#    <queries>\n        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="upi"/></intent>\n    </queries>\n</manifest>#' "$M"
  fi
fi
# Block screenshots on screens that show a trainer's PDF (method channel "gymmantra/secure")
MA=$(find android/app/src/main -name 'MainActivity.kt' | head -1)
if [ -n "$MA" ]; then
  PKG=$(sed -n 's/^package \(.*\)$/\1/p' "$MA")
  cat > "$MA" <<KT
package $PKG

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var upiResult: MethodChannel.Result? = null
    private val upiRequest = 4711

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gymmantra/secure").setMethodCallHandler { call, result ->
            when (call.method) {
                "on" -> { window.addFlags(WindowManager.LayoutParams.FLAG_SECURE); result.success(null) }
                "off" -> { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE); result.success(null) }
                // Phone name for "Logged-in devices" (e.g. "Xiaomi Redmi Note 12").
                "device" -> {
                    val maker = android.os.Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                    val model = android.os.Build.MODEL
                    result.success(if (model.lowercase().startsWith(maker.lowercase())) model else "$maker $model")
                }
                else -> result.notImplemented()
            }
        }
        // UPI apps installed on this phone (real name + real icon), and paying with one of them.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gymmantra/upi").setMethodCallHandler { call, result ->
            when (call.method) {
                "apps" -> {
                    try {
                        val pm = packageManager
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("upi://pay"))
                        val list = pm.queryIntentActivities(intent, 0)
                        val seen = HashSet<String>()
                        val out = ArrayList<Map<String, Any>>()
                        for (ri in list) {
                            val pkg = ri.activityInfo.packageName
                            if (!seen.add(pkg)) continue
                            val label = ri.loadLabel(pm).toString()
                            val d = ri.loadIcon(pm)
                            val size = 112
                            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                            val c = Canvas(bmp)
                            d.setBounds(0, 0, size, size)
                            d.draw(c)
                            val bos = ByteArrayOutputStream()
                            bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
                            out.add(mapOf("package" to pkg, "name" to label, "icon" to bos.toByteArray()))
                        }
                        result.success(out)
                    } catch (e: Exception) {
                        result.error("UPI_LIST", e.message, null)
                    }
                }
                "pay" -> {
                    val uri = call.argument<String>("uri")
                    val pkg = call.argument<String>("package")
                    if (uri == null) { result.error("NO_URI", "No payment link", null); return@setMethodCallHandler }
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
                    if (pkg != null) intent.setPackage(pkg)
                    try {
                        upiResult?.success(null)
                        upiResult = result
                        startActivityForResult(if (pkg == null) Intent.createChooser(intent, "Pay with") else intent, upiRequest)
                    } catch (e: Exception) {
                        upiResult = null
                        result.error("NO_APP", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == upiRequest) {
            // UPI apps answer like "txnId=..&responseCode=00&Status=SUCCESS&txnRef=.."
            val r = data?.getStringExtra("response") ?: data?.getStringExtra("Status")
            upiResult?.success(r ?: (if (resultCode == RESULT_OK) "" else null))
            upiResult = null
        }
    }
}
KT
fi
# Photo cropper screen (image_cropper / uCrop)
grep -q 'UCropActivity' "$M" || sed -i 's#</application>#    <activity android:name="com.yalantis.ucrop.UCropActivity" android:screenOrientation="portrait" android:theme="@style/GmCropTheme"/>\n    </application>#' "$M"
sed -i 's#android:theme="@style/Theme.AppCompat.Light.NoActionBar"/>#android:theme="@style/GmCropTheme"/>#' "$M"
# Crop screen theme. On Android 15+ it opts out of edge-to-edge so the Done/tick button is not hidden under the status bar.
R=android/app/src/main/res
mkdir -p "$R/values" "$R/values-v35"
cat > "$R/values/gm_crop_theme.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="GmCropTheme" parent="Theme.AppCompat.Light.NoActionBar"/>
</resources>
XML
cat > "$R/values-v35/gm_crop_theme.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="GmCropTheme" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="android:windowOptOutEdgeToEdgeEnforcement">true</item>
    </style>
</resources>
XML
# App icon (logo C: dumbbell + heartbeat)
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  cp "assets/icon/mipmap-$d.png" "android/app/src/main/res/mipmap-$d/ic_launcher.png"
done
# Dark launch background so the app never flashes white before the animated splash
for f in android/app/src/main/res/drawable/launch_background.xml android/app/src/main/res/drawable-v21/launch_background.xml; do
  if [ -f "$f" ]; then
    cat > "$f" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item><color android:color="#0D1015"/></item>
</layer-list>
XML
  fi
done
grep -n 'INTERNET\|android:label\|UCrop' "$M"
