# Linux ARM64 builds

The ARM64 CI jobs build on native Ubuntu ARM64 runners and target
`aarch64-unknown-linux-gnu`. Native releases provide
`flutter-servo-native-linux-arm64-<version>.tar.gz` with a SHA-256 sidecar.
The Flutter native assets hook selects this archive for Linux ARM64.

The GTK3 example builds to `build/linux/arm64/release/bundle` from the
example directory. Released bundle and package filenames include
`linux-aarch64-gtk3`. The DEB architecture is `arm64` and the RPM
architecture is `aarch64`. GTK4 remains x64-only in CI pending a matching
custom Flutter SDK.

The reusable native and Linux browser workflows list the build dependencies.
Ubuntu-built binaries require a compatible target runtime and are not
guaranteed to run against a Yocto sysroot. Build Servo against the target
sysroot when targeting Yocto.
