import java.util.Properties

// Release signing, read from android/key.properties, which is gitignored and
// points at a keystore kept outside the repository.
//
// The keystore is not recoverable and not replaceable: an app already
// installed can only be updated by a build signed with the SAME key, and Play
// binds the listing to it permanently. Losing this file means every tester
// uninstalls and reinstalls; publishing it means anyone can ship an update
// that looks like ours.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.abcom.aurav5"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.abcom.aurav5"
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
            // Only defined when key.properties is present. A checkout without
            // it still builds debug; `release` then falls back below rather
            // than failing at configuration time.
            if (keystoreProperties.getProperty("storeFile") != null) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storeType = keystoreProperties.getProperty("storeType") ?: "PKCS12"
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Falls back to debug signing when key.properties is absent, so a
            // fresh clone can still run --release. A build signed with the
            // debug key must never be distributed: every machine has a
            // different debug key, so testers cannot upgrade to a real release
            // without uninstalling first, losing their local database.
            signingConfig = if (keystoreProperties.getProperty("storeFile") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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

dependencies {
    // The BoM fixes one consistent set of Firebase versions, which is why the
    // individual dependencies below carry none: adding a version there
    // overrides the BoM and is how mismatched Firebase libraries get into a
    // build.
    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))

    // Analytics starts collecting device and usage data as soon as the app
    // runs — no code required. Nothing in this app calls it; it is here
    // because the Firebase console's setup flow includes it. Delete this line
    // if that collection is not wanted. App Distribution does not need it, or
    // any of the SDK: distributing a build needs only the APK and the app id.
    implementation("com.google.firebase:firebase-analytics")
}
