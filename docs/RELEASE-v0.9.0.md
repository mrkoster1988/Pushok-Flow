# Pushok Flow 0.9.0 — Android release-build prerequisites

- Fixed WireGuard tunnel identifier to `pushok_flow` (no spaces).
- Added INTERNET permission to main AndroidManifest, not only debug overlays.
- CI now runs `aapt` against the built APK to check package ID, INTERNET permission and presence of WireGuard service.
- Added targeted automated regression tests.
- No working APK or hardware test has been confirmed.
- Native backend integration is still experimental; the app is not production-ready.
- Future tasks: actually run Android CI, verify manifest exported=false and WireGuard service lifecycle, test physical device and excluded packages.