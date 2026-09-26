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

            val defaultExternalKeystore = file("${System.getProperty("user.home")}/.android/media_server_release.keystore")
            if (keyStoreFile != null && file(keyStoreFile).exists()) {
                storeFile = file(keyStoreFile)
                storePassword = keyStorePassword
                keyAlias = keyStoreAlias
                keyPassword = keyPasswordValue
            } else if (defaultExternalKeystore.exists()) {
                storeFile = defaultExternalKeystore
                storePassword = System.getenv("MEDIA_SERVER_KEYSTORE_PASSWORD") ?: "MediaServerRelease2026!"
                keyAlias = System.getenv("MEDIA_SERVER_KEY_ALIAS") ?: "media_server_key"
                keyPassword = System.getenv("MEDIA_SERVER_KEY_PASSWORD") ?: "MediaServerRelease2026!"
                enableV1Signing = true
                enableV2Signing = true
            } else {
                // Fallback to debug keystore for development builds when release keystore is absent
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
