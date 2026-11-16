import com.android.build.api.dsl.ApplicationExtension
import org.gradle.kotlin.dsl.configure
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

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

// Read Flutter's selected NDK version from its Gradle extension before configuring AGP.
val flutterNdkVersion = flutter.ndkVersion

// Configure AGP through the supported public DSL interface. AGP 9 deprecates the
// legacy BaseAppModuleExtension android {} accessor, so do not use that accessor.
extensions.configure<ApplicationExtension>("android") {
    namespace = "app.secretplay"
    compileSdk = 36
    ndkVersion = flutterNdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "app.secretplay"
        // Flutter's supported Android baseline for this project is API 24.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    androidResources {
        // Keep the same language filtering behavior using the current AGP API.
        localeFilters.add("en")
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = project.file(uploadKeystorePath!!)
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
                storeType = "JKS"
            }
        }
    }

    buildTypes {
        getByName("release") {
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

// Kotlin 2.4+ uses the typed compilerOptions DSL instead of deprecated kotlinOptions.
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core-ktx:1.15.0")
}
