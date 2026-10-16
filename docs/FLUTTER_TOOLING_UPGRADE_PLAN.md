# Implementation Plan: Flutter Client Tooling Upgrade to Latest (Gradle 9.8.1, AGP 9.4.1, Kotlin 2.4.21)

## 1. Scope

### What Changes:
1. **Gradle Wrapper (`flutter_client/android/gradle/wrapper/gradle-wrapper.properties`)**:
   - Upgrade `distributionUrl` to `https://services.gradle.org/distributions/gradle-9.8.1-all.zip`.
2. **Android Gradle Plugin (`flutter_client/android/settings.gradle.kts`)**:
   - Upgrade `com.android.application` to version `9.4.1`.
   - Upgrade `org.jetbrains.kotlin.android` to version `2.4.21`.
3. **Gradle Properties (`flutter_client/android/gradle.properties`)**:
   - Ensure `android.builtInKotlin=true` is set.
   - Set `android.newDsl=false` (to activate the AGP 9 legacy extension compatibility bridge required by the Flutter Gradle Plugin).
   - Retain `kotlin.incremental=false` (to safeguard against Windows microSD/USB memory-mapped cache locks).
4. **App Build Script (`flutter_client/android/app/build.gradle.kts`)**:
   - Verify removal of deprecated `kotlin { compilerOptions {} }` block in favor of modern AGP/Kotlin conventions.

### What Deliberately Does Not Change:
- Application code in `flutter_client/lib/`.
- App dependencies in `pubspec.yaml` (already updated via `flutter pub upgrade`).
- Backend Rust/Flask services.
- Android signing configurations and keystore resolution logic.

---

## 2. Exit Criteria
1. `flutter clean` executes cleanly with exit code 0.
2. `flutter build apk --debug` executes successfully with exit code 0 using:
   - Gradle `9.8.1`
   - Android Gradle Plugin `9.4.1`
   - Kotlin `2.4.21`
3. A verified debug APK artifact is generated at `flutter_client/build/app/outputs/flutter-apk/app-debug.apk` with a fresh timestamp and expected file size (~200MB+).
4. Zero unhandled Gradle deprecation or compiler errors.

---

## 3. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Flutter Gradle Plugin Cast Failure** | Build fails with `ClassCastException` trying to cast `ApplicationExtensionImpl` to `AbstractAppExtension`. | Setting `android.newDsl=false` activates AGP 9's compatibility layer, exposing the legacy interface to FGP. |
| **Gradle 9.6+ Internal API Removal** | Old plugins calling internal Gradle APIs fail. | AGP 9.4.1 is native to Gradle 9 and does not rely on the removed `InternalProblems` internal API. |
| **First-Run Network Downloads** | Gradle 9.8.1 wrapper zip and AGP 9.4.1 artifacts must download from remote Maven/services. | Handled via bounded background commands with clear logging and timeout resilience. |
| **Windows MicroSD / USB Volume Cache Locks** | Corrupted incremental cache locks on `assemble` tasks. | Enforce `kotlin.incremental=false` in `gradle.properties`. |

---

## 4. Open Decisions

1. **New DSL Enforcement**:
   - The Flutter Gradle Plugin in Flutter 3.47.7 requires `android.newDsl=false` when running on AGP 9+. This is the official Google/Flutter transition bridge for AGP 9.0+. Once Flutter releases an engine update with an updated FGP natively implementing the new DSL without casting to `AbstractAppExtension`, this flag can be flipped to `true`.
   - *Decision:* Proceed with `android.newDsl=false` on AGP 9.4.1 + Gradle 9.8.1.

---

## 5. Verification Steps
1. Apply the version changes to `gradle-wrapper.properties`, `settings.gradle.kts`, and `gradle.properties`.
2. Run `flutter clean`.
3. Run `flutter build apk --debug` in `flutter_client/`.
4. Inspect the output logs and verify the generated APK artifact metadata.
5. Create a comprehensive walkthrough document documenting all findings and verification results.
