plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "np.com.thapaalish.pocketshare"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "np.com.thapaalish.pocketshare"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // cloudflared is shipped as a prebuilt arm64 executable, so this is
        // the only ABI the app can run on.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            // cloudflared must exist as a real file in nativeLibraryDir so the
            // app can exec it. With the modern default it stays packed inside
            // the APK and is only mmap'd, which gives no executable path.
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // TODO: replace with a real upload key before distributing.
            signingConfig = signingConfigs.getByName("debug")
            // Both off together: shrinkResources requires minify, and R8 has
            // no value here while the app is sideloaded and already small
            // relative to the 25 MB cloudflared payload.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
