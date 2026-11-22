"""flutter create ke baad Android manifest/gradle ko patch karta hai.
Size fix: sirf arm64-v8a native libs (stockfish ki .so har ABI ke liye alag hoti hai, isliye APK 300MB tak jaata tha)
aur native libs ko APK mein compress karna.
"""
import re
from pathlib import Path

# ---------------- Manifest ----------------
m = Path("android/app/src/main/AndroidManifest.xml")
text = m.read_text()

perms = [
    "android.permission.INTERNET",
    "android.permission.SYSTEM_ALERT_WINDOW",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
    "android.permission.READ_MEDIA_IMAGES",
]
add = "".join(
    f'    <uses-permission android:name="{p}"/>\n'
    for p in perms
    if f'android:name="{p}"' not in text
)
if "READ_EXTERNAL_STORAGE" not in text:
    add += '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>\n'
if add:
    text = text.replace("<application", add + "    <application", 1)

service = """
        <service
            android:name="flutter.overlay.window.flutter_overlay_window.OverlayService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="Floating chess analysis button over other apps"/>
        </service>
"""
if "OverlayService" not in text:
    text = text.replace("</application>", service + "    </application>", 1)
m.write_text(text)
print("Manifest OK")

# ---------------- Gradle ----------------
KTS = {
    "android": (
        "    lint {\n        checkReleaseBuilds = false\n        abortOnError = false\n    }\n"
        "    packaging {\n        jniLibs {\n            useLegacyPackaging = true\n        }\n    }\n"
    ),
    "ndk": (
        "        ndk {\n            abiFilters.clear()\n            abiFilters.addAll(listOf(\"arm64-v8a\"))\n        }\n"
    ),
}
GROOVY = {
    "android": (
        "    lint {\n        checkReleaseBuilds false\n        abortOnError false\n    }\n"
        "    packagingOptions {\n        jniLibs {\n            useLegacyPackaging = true\n        }\n    }\n"
    ),
    "ndk": (
        "        ndk {\n            abiFilters.clear()\n            abiFilters.add('arm64-v8a')\n        }\n"
    ),
}

for name, blocks in [
    ("android/app/build.gradle.kts", KTS),
    ("android/app/build.gradle", GROOVY),
]:
    p = Path(name)
    if not p.exists():
        continue
    t = p.read_text()
    if "useLegacyPackaging" in t:
        print("already patched:", name)
        continue
    # android { ... } ke shuru mein lint + packaging
    t = re.sub(r"(\bandroid\s*\{[ \t]*\n)", lambda mo: mo.group(1) + blocks["android"], t, count=1)
    # defaultConfig { ... } ke shuru mein ndk abiFilters
    if re.search(r"defaultConfig\s*\{", t):
        t = re.sub(r"(defaultConfig\s*\{[ \t]*\n)", lambda mo: mo.group(1) + blocks["ndk"], t, count=1)
    else:
        t = re.sub(
            r"(\bandroid\s*\{[ \t]*\n)",
            lambda mo: mo.group(1) + "    defaultConfig {\n" + blocks["ndk"] + "    }\n",
            t,
            count=1,
        )
    p.write_text(t)
    print("gradle patched:", name)
