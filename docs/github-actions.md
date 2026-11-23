# GitHub Browser Builds

**Browser CI** runs on pushes, pull requests, and manual runs. After the shared
checks pass, it builds the same example browser for Linux x64 and Windows x64.
Both bundles contain the login, licenses, documentation, and video demos. Linux
uploads a GTK4 tarball and RPM. Windows uploads a ZIP. Downloads appear under
the run's **Artifacts** section and are retained for 14 days.

**Servo Native Assets** uploads separate Linux x64 and Windows x64 archives for
embedders. Both variants build on native-related pushes and pull requests,
manual runs, and `native-v*` tags.

The build uses the public Flutter GTK4 fork and precompiled engine artifacts:

- Flutter fork revision: `de20cd2c06847dbc887df574c585484c447a257c`
- Prebuilt engine: `f2b4375245d63bdb7007d42b4032e0e8d079780c`
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

`v*` tags trigger **Browser Release**, which runs the same Flutter, Rust, and
packaging checks as CI before building the Linux and Windows bundles and GTK4
RPM. The release workflow can also
be run manually with an existing tag. It resolves the tag once, tests and
builds that commit, and verifies that the tag still names that commit before
publishing. Build provenance records the checked-out commit, including when a
manual release targets a tag different from the workflow's branch.

Public GitHub
release publishing is enabled only when the repository variable
`BROWSER_LICENSE` contains the chosen SPDX identifier and a real root `LICENSE`
file exists. Until then, CI artifacts declare `LicenseRef-Unspecified`; this is
metadata for development builds and does not grant a license. The placeholder
package license must also be resolved before distributing the reusable package.

Workflow files are in `.github/workflows/`; they run when this repository is
hosted or mirrored on GitHub with Actions enabled. No remote workflow has been
dispatched by adding these files locally.
