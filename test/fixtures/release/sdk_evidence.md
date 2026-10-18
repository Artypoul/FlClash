# Android SDK output evidence

These sanitized observations come from the existing `build/app/outputs/flutter-apk/app-debug.apk` (197,183,036 bytes). They describe a local debug artifact only and are not release-signer or release-package evidence. The fixtures contain selected tool output; no full manifest or APK contents are included.

Tools used:

- Android SDK command-line tools package revision `22.0`; executable `apkanalyzer.bat` at `D:/Development/android-sdk/cmdline-tools/latest/bin/apkanalyzer.bat`.
- Android SDK build-tools package revision `37.0.0`; `apksigner.bat version` returned `0.9`.
- Java runtime: `D:/Development/java/jdk-17.0.20.1+1`.

Commands, from the repository root:

```powershell
apkanalyzer manifest application-id build/app/outputs/flutter-apk/app-debug.apk
apkanalyzer manifest version-name build/app/outputs/flutter-apk/app-debug.apk
apkanalyzer manifest version-code build/app/outputs/flutter-apk/app-debug.apk
apkanalyzer manifest debuggable build/app/outputs/flutter-apk/app-debug.apk
apkanalyzer manifest print build/app/outputs/flutter-apk/app-debug.apk | Select-String '<application|android:debuggable|</application>'
apkanalyzer manifest print build/app/outputs/flutter-apk/app-debug.apk | Select-String 'android:testOnly'
apkanalyzer files list build/app/outputs/flutter-apk/app-debug.apk | Where-Object { $_ -match '^/lib/(arm64-v8a|armeabi-v7a|x86_64)/[^/]+\.so$' }
apksigner verify --print-certs build/app/outputs/flutter-apk/app-debug.apk
```

The `android:testOnly` filter returned no matching line; the corresponding fixture records that empty-match result. The SDK tool has no dedicated `testOnly` manifest query. The ABI path fixture shows native libraries for exactly `arm64-v8a`, `armeabi-v7a`, and `x86_64`. The certificate fixture retains only the V2 signer distinguished name and SHA-256 fingerprint; the signer is Android Debug (`C=US, O=Android, CN=Android Debug`), so it must only be treated as a negative/debug certificate example.
