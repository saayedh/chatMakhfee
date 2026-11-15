plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val uploadKeystorePath = System.getenv("SECRETPLAY_UPLOAD_KEYSTORE")
val uploadStorePassword = System.getenv("SECRETPLAY_STORE_PASSWORD")
val uploadKeyAlias = System.getenv("SECRETPLAY_KEY_ALIAS")
val uploadKeyPassword = System.getenv("SECRETPLAY_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    uploadKeystorePath,
    uploadStorePassword,
    uploadKeyAlias,
    uploadKeyPassword,
).all { !it.isNullOrBlank() } && uploadKeystorePath?.let { file(it).isFile } == true

// Never silently sign a distributable release with Android's public debug key.
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseTaskRequested && !hasReleaseSigning) {
    throw GradleException(
        "Release signing is not configured. Set SECRETPLAY_UPLOAD_KEYSTORE, " +
            "SECRETPLAY_STORE_PASSWORD, SECRETPLAY_KEY_ALIAS and SECRETPLAY_KEY_PASSWORD. " +
            "Debug signing is intentionally not used for release builds."
    )
}

android {
    namespace = "app.secretplay"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "app.secretplay"
        // Flutter 3.38's supported Android baseline is API 24.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        resourceConfigurations += listOf("en")
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = file(uploadKeystorePath!!)
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
                storeType = "JKS"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        jniLibs {
            // vodozemac ships its Rust .so per ABI; do not strip what cargokit built.
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core-ktx:1.15.0")
}
