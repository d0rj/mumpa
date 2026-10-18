import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigning = listOf(
    "MUMPA_KEYSTORE_PATH", "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD",
).associateWith { System.getenv(it)?.takeIf(String::isNotBlank) }
val hasReleaseSigning = releaseSigning.values.any { it != null }
require(!hasReleaseSigning || releaseSigning.values.all { it != null }) {
    "Configure all four persistent Android signing environment variables."
}
val releaseRequested = gradle.startParameter.taskNames.any {
    val task = it.substringAfterLast(':').lowercase()
    task.contains("release") || task in setOf("build", "buildneeded", "builddependents", "assemble", "bundle")
}
require(!releaseRequested || hasReleaseSigning) {
    "Persistent Android signing is required. Build with tools/build-android.ps1; debug fallback is disabled."
}
// Aggregate Gradle tasks such as `build` can include a release indirectly.
gradle.taskGraph.whenReady {
    require(hasReleaseSigning || allTasks.none { it.name.contains("release", ignoreCase = true) }) {
        "Persistent Android signing is required for every release task."
    }
}
if (hasReleaseSigning) {
    val expected = rootProject.file("release-signing.sha256").readText().trim().lowercase()
    require(expected.matches(Regex("[a-f0-9]{64}"))) { "Invalid pinned Android certificate fingerprint." }
    val keyStore = KeyStore.getInstance(
        file(releaseSigning.getValue("MUMPA_KEYSTORE_PATH")!!),
        releaseSigning.getValue("ANDROID_KEYSTORE_PASSWORD")!!.toCharArray(),
    )
    val alias = releaseSigning.getValue("ANDROID_KEY_ALIAS")!!
    require(keyStore.isKeyEntry(alias)) { "Android signing alias has no private key." }
    require(keyStore.getKey(alias, releaseSigning.getValue("ANDROID_KEY_PASSWORD")!!.toCharArray()) != null) {
        "Android signing private key is unavailable."
    }
    val actual = MessageDigest.getInstance("SHA-256").digest(keyStore.getCertificate(alias).encoded)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    require(actual == expected) { "Android signing certificate differs from the pinned release identity." }
}

android {
    namespace = "app.mumpa.mumpa"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    packaging {
        jniLibs.useLegacyPackaging = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.mumpa.mumpa"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseSigning.getValue("MUMPA_KEYSTORE_PATH")!!)
                storePassword = releaseSigning.getValue("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = releaseSigning.getValue("ANDROID_KEY_ALIAS")
                keyPassword = releaseSigning.getValue("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
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
