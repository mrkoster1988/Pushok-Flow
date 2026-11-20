# v0.3.0 — WireGuard Android integration prototype

- Added Android native MethodChannel for WireGuard `GoBackend` connect, disconnect, status and Android VPN permission.
- Added explicit routing exclusions using `ExcludedApplications` in parsed WireGuard config.
- Added configuration input to the home UI. Config is passed in memory and not logged or persisted.
- Prevented changing bypass list during active connection.
- Included AndroidManifest and Gradle instructions for official `com.wireguard.android:tunnel` artifact.

**Not verified:** Android compilation, real-device handshake, DNS or IP leak tests, iOS and reconnect after activity/process restart. No finished APK.