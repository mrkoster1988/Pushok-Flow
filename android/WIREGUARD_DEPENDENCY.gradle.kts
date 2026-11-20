// Copy into android/app/build.gradle.kts after flutter create --platforms android.
// Pinned WireGuard tunnel library. Do not use dynamic '+' versions.
dependencies {
    implementation("com.wireguard.android:tunnel:1.0.20260102")
}