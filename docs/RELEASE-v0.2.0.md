# Pushok Flow v0.2.0 — development snapshot

## Implemented (source only)
- Flutter MethodChannel for launchable Android apps and private persistence of bypass package names.
- Kotlin helper to apply chosen packages to a VpnService.Builder (not yet invoked by a tunnel backend).
- Dynamic app selection screen and local deterministic guidance labelled **Pushok ИИ**.
- JSON schema for recommended routing rules (not automatically applied).

## Not implemented
- Real WireGuard tunnel, backend integration, protection of transport socket, authentication.
- VPN active-state callbacks, device tests, automatic rule download and signature verification.
- Live/LLM-based AI and AI learning, iOS app exclusion, automatic APK installation.
- Android/iOS compilation in this environment (Flutter and Android SDK not installed).

## Next release criteria
1. Choose supported WireGuard backend and wire its Builder creation to per-app exclusion (without invasive unsafe hacks).
2. WireGuard config import with secure key storage and user VPN consent.
3. End-to-end test on physical Android devices including bank apps that detect VPN presence.
4. Signed release update manifests and compatible app-store flows.