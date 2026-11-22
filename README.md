# Chess Agent (Flutter, Android) — Floating Button Edition

Screenshot → board recognition (on-device) → Stockfish top 3 → OpenRouter se "kyun?".

**Naya feature:** Floating ♟ button jo Lichess / kisi bhi app ke upar chalta hai.

## APK banane ke 2 tareeqe

**A) Apne PC par (Flutter installed ho):**
```bash
flutter create --platforms=android --project-name chess_agent --org com.istehsaan .
flutter pub get
python3 tools/patch_android.py
flutter build apk --release --target-platform android-arm64
```
APK: `build/app/outputs/flutter-apk/app-release.apk`

> **Size:** `--split-per-abi` mat use karo (patch script ke abiFilters se conflict karta hai). Bina patch ke fat APK (sab ABIs) ~300MB ban jaati hai.

**B) Bina Flutter install kiye:** is folder ko GitHub repo mein push karo, Actions tab → "Build APK" → Run workflow, phir artifact se APK download karo.

## Android permissions (zaruri)

`android/app/src/main/AndroidManifest.xml` mein yeh hona chahiye:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>
```

`<application>` tag ke andar:

```xml
<service
    android:name="flutter.overlay.window.flutter_overlay_window.OverlayService"
    android:exported="false"
    android:foregroundServiceType="specialUse">
  <property
      android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
      android:value="Floating chess analysis button over other apps"/>
</service>
```

CI workflow `tools/patch_android.py` se yeh permissions + service automatically inject karta hai.
Local build ke liye `flutter create ...` ke baad `python3 tools/patch_android.py` chala do.

## Use (normal)

1. Settings: OpenRouter key daalo (optional — "Kyun?" ke liye).
2. **Calibrate**: Lichess par naya game (White neeche), screenshot lo, grid fit karo, Save. (Ek baar, piece set badlo to dobara.)
3. Game ke beech screenshot lo → app mein **Screenshot** choose karo → best moves.
4. Galat piece dikhe to square tap karke theek karo. White neeche / kiski baari toggles set rakho.

## Use (Floating Button)

1. App kholo → **Floating Button On Karo** dabao.
2. Pehli baar "Display over other apps" permission allow karo.
3. Ab Lichess (ya koi bhi chess app) kholo aur khelo.
4. Jab move chahiye:
   - **Power + Volume Down** se system screenshot lo (board clear dikhna chahiye).
   - Screen pe floating ♟ button pe **tap** karo.
   - App aayegi aur gallery/recent se **latest screenshot** choose karo.
5. Best moves aa jayenge.

> **Note:** Android security ki wajah se koi normal app bina user consent ke doosri app ka screen seedha capture nahi kar sakti. Isliye abhi flow yeh hai: aap system screenshot lo → floating button se app open → latest image choose.  
> Pure auto-capture (MediaProjection) baad mein add kiya ja sakta hai, lekin usme bhi ek baar system dialog aata hai.

## Hadd

- Sirf practice, analysis aur computer ke against khelne ke liye. Insaanon ke live games mein engine move lena Lichess par cheating hai.
- En passant image se nahi pata chalta; castling rights king/rook ki jagah se guess hoti hain.

## Floating button nahi dikhe to

- Settings → Apps → Chess Agent → **Display over other apps** ON.
- Xiaomi/Oppo/Vivo/Realme: **Display pop-up windows while running in background** bhi ON karo, aur battery saver/autostart allow karo.
- `overlayMain()` main.dart mein hai (plugin ki shart) — isko wahan se mat hatana.
