group = "ca.richyoung.flutter_servo"
version = "1.0-SNAPSHOT"

plugins {
    id("com.android.library")
}

android {
    namespace = "ca.richyoung.flutter_servo"
    compileSdk = flutter.compileSdkVersion
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":webview_flutter_android"))
}
