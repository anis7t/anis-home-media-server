import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "in.anisparvez.media_server_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "in.anisparvez.media_server_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
            create("release") {
                val keyStoreFile = (keystoreProperties["storeFile"] as? String)
                    ?: System.getenv("MEDIA_SERVER_KEYSTORE_PATH")
                val keyStorePassword = (keystoreProperties["storePassword"] as? String)
                    ?: System.getenv("MEDIA_SERVER_KEYSTORE_PASSWORD")
                val keyStoreAlias = (keystoreProperties["keyAlias"] as? String)
                    ?: System.getenv("MEDIA_SERVER_KEY_ALIAS")
                val keyPasswordValue = (keystoreProperties["keyPassword"] as? String)
                    ?: System.getenv("MEDIA_SERVER_KEY_PASSWORD")

                // The release keystore lives outside the repository and its password is supplied
                // locally - via flutter_client/android/key.properties (git-ignored) or the
                // MEDIA_SERVER_KEYSTORE_* environment variables. No credential is stored in this file.
                val defaultExternalKeystore = file("${System.getProperty("user.home")}/.android/media_server_release.keystore")
                val resolvedStoreFile = when {
                    keyStoreFile != null && file(keyStoreFile).exists() -> file(keyStoreFile)
                    defaultExternalKeystore.exists() -> defaultExternalKeystore
                    else -> null
                }

                val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
                val allowDebugSigning = System.getenv("MEDIA_SERVER_ALLOW_DEBUG_SIGNING") == "1"

                if (resolvedStoreFile != null) {
                    if (keyStorePassword.isNullOrBlank() || keyPasswordValue.isNullOrBlank()) {
                        throw GradleException(
                            "Release signing is not configured for ${resolvedStoreFile.name}: the keystore password is missing. " +
                                "Create flutter_client/android/key.properties with storeFile/storePassword/keyAlias/keyPassword, " +
                                "or export MEDIA_SERVER_KEYSTORE_PASSWORD and MEDIA_SERVER_KEY_PASSWORD."
                        )
                    }
                    storeFile = resolvedStoreFile
                    storePassword = keyStorePassword
                    keyAlias = keyStoreAlias ?: "media_server_key"
                    keyPassword = keyPasswordValue
                    enableV1Signing = true
                    enableV2Signing = true
                } else if (releaseRequested && !allowDebugSigning) {
                    // Refusing here is deliberate: a debug-signed release APK can never be installed as
                    // an update over the real app, so silently producing one wastes a whole release.
                    throw GradleException(
                        "No release keystore found. Point MEDIA_SERVER_KEYSTORE_PATH or key.properties at the " +
                            "keystore, or set MEDIA_SERVER_ALLOW_DEBUG_SIGNING=1 for a throwaway build."
                    )
                } else {
                    // Development builds only: fall back to the debug keystore.
                    initWith(signingConfigs.getByName("debug"))
                }
            }
        }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
