# Pushok Flow v0.3.0 — Android integration

1. Install Flutter SDK + Android SDK/NDK. From project root run `flutter create --platforms=android --org shop.pushok --project-name pushok_flow .`.
2. Replace generated `android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt` with `native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt`; copy `WireGuardRouting.kt` from same source directory.
3. In `android/app/build.gradle.kts` add under `dependencies`:
   `implementation("com.wireguard.android:tunnel:1.0.20260102")`
4. In `android/app/src/main/AndroidManifest.xml` under `<application>` register WireGuard service:

```xml
<service android:name="com.wireguard.android.backend.GoBackend$VpnService"
  android:permission="android.permission.BIND_VPN_SERVICE" android:exported="true">
  <intent-filter><action android:name="android.net.VpnService" /></intent-filter>
</service>
```

5. Under `<manifest>` include these queries:

```xml
<queries>
  <intent><action android:name="android.intent.action.MAIN" />
    <category android:name="android.intent.category.LAUNCHER" /></intent>
</queries>
```

6. Ensure minSdkVersion supported by WireGuard library. Build: `flutter build apk --debug`. Debug on real device with real WG server (no test keys bundled).
7. Real VPN permission prompt must appear on first connection. Status UP means backend established, **not necessarily Internet reachability**. Test IPv4, IPv6, DNS, Wi-Fi/cellular, app bypass and Android lockdown.

## Security and limitations

- Config and private key passed in memory via Flutter MethodChannel; not stored in SharedPreferences. Closing app may lose config; secure persistent storage is future work.
- Package exclusions are passed in WireGuard `ExcludedApplications` config; GoBackend itself applies them to VPN Builder before establish. No fork required.
- Changing exclusions while tunnel active is blocked; disconnect first.
- A known Android limitation: Always-on lockdown may prevent bypassed applications from using direct Internet; tell user clearly rather than claiming bypass works.
- Android runtime/compile **not verified** here: Flutter/Android SDK are unavailable. Do not ship to production without signed builds and device tests.
- This prototype does not yet implement foreground lifecycle handling, robust persistent tunnel reconnect, encrypted config storage, or kill-switch UX.