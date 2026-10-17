import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// android/key.properties is gitignored. It holds the release keystore path and
// credentials, so they are never checked in with the project.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

val isReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}
if (isReleaseBuild && !hasReleaseKeystore) {
    error(
        "Release signing is not configured. Create android/key.properties and " +
            "android/app/upload-keystore.jks before building a release.",
    )
}

android {
    namespace = "com.asrumon.greenbiz"
    // 37, not `flutter.compileSdkVersion`: permission_handler_android 14.x
    // publishes AAR metadata demanding compileSdk 37, and the build fails at
    // :app:checkDebugAarMetadata if the app compiles against anything lower.
    // Compiling against a higher SDK is backward compatible, so this is safe to
    // raise; it can go back to `flutter.compileSdkVersion` once Flutter's own
    // default reaches 37.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.asrumon.greenbiz"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter.minSdkVersion is 21 or higher on every supported Flutter
        // channel, which satisfies both flutter_sms_inbox (21+) and
        // permission_handler's SMS APIs (23+). Left on the Flutter default so a
        // toolchain upgrade can raise it without a manual edit here.
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
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // The configuration check above guarantees this exists for a
            // release build; the fallback is only for tooling that configures
            // the release variant on a machine without the signing key.
            signingConfig = if (hasReleaseKeystore) {
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
