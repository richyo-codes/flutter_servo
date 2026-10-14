# GitHub Browser Builds

GitHub Actions builds and tests the package and browser on pushes, pull requests,
and manual runs of **Browser CI**. The GTK4 job produces an x86_64 release RPM
and a separate browser bundle tarball preserving executable permissions.
Artifacts appear under the run's **Artifacts**
section and are retained for 14 days.

The build uses the public Flutter GTK4 fork and precompiled engine artifacts:

- Flutter fork revision: `1e75e574e6a580fff095ebe83343276fd29df100`
- Prebuilt engine: `41de58d04229db1294f191f7965e6009fb1bd7a2`
- FVM: `4.2.0`
- Runner: Ubuntu 26.04, x86_64

Ubuntu 26.04 is a [supported GitHub-hosted runner label](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).
Some versions of actionlint still require ignoring its unknown-label warning
for this runner when validating locally.

No local Flutter/Servo/Surfman checkout is required on the runner. The package's
Rust toolchain and public Servo/Surfman pins remain authoritative. CI installs
Python 3.11 for Servo's generated bindings and builds both Flutter and Rust in
release mode. Common Flutter assets use Flutter's usual storage; the custom
storage URL is scoped to the engine setup.

The engine installer verifies debug/profile/release archive contents and GTK
linkage. The bundle check requires AOT assets, GTK4, the native Servo entry
point, and resolved ELF dependencies. A native probe exercises local HTML,
Unicode composition, context menus, and stale-response rejection under Xvfb
without screenshots.

The RPM installs the complete relocatable bundle under
`/usr/lib64/flutter-servo-browser-gtk4/` and provides the command
`flutter-servo-browser-gtk4` and a desktop entry. Packaging rewrites build-tree
RUNPATHs in a temporary copy. Automatic RPM requirements retain actual glibc,
libstdc++, GTK, graphics, and other system ABI requirements, so this is intended
for sufficiently recent RPM distributions, not arbitrary older Fedora/RHEL
versions. The requirements are uploaded alongside the RPM. GPU sharing remains
opt-in through `FLUTTER_SERVO_GPU_TEXTURES=1`.

Build an RPM locally from an existing release bundle:

```bash
bash tools/build_browser_rpm.sh --version 0.1.0
sudo dnf install ./build/packages/rpm/gtk4/*.rpm
flutter-servo-browser-gtk4
```

Requires an x86_64 Linux host with `rpm`, `rpmbuild`, `patchelf`, `binutils`,
and the bundle's system libraries. Use `--bundle-dir` and `--out-dir` to select
other paths. The original bundle is left untouched.

`v*` tags trigger **Browser Release**, which builds the same RPM. Public GitHub
release publishing is enabled only when the repository variable
`BROWSER_LICENSE` contains the chosen SPDX identifier and a real root `LICENSE`
file exists. Until then, CI artifacts declare `LicenseRef-Unspecified`; this is
metadata for development builds and does not grant a license. The placeholder
package license must also be resolved before distributing the reusable package.

Workflow files are in `.github/workflows/`; they run when this repository is
hosted or mirrored on GitHub with Actions enabled. No remote workflow has been
dispatched by adding these files locally.
