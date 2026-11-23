# GitHub Browser Builds

**Browser CI** runs on pushes, pull requests, and manual runs. It builds the
Servo native libraries once for Linux x64 and Windows x64. The widget tests
use the Linux library, and each browser bundle uses the library for its
platform. Each consumer checks the archive checksum and source commit before
bundling it. After the shared checks pass, CI builds the example browser.
All bundles contain the login, licenses, documentation, and video demos. Linux
uploads a tarball, RPM, and DEB for each GTK variant. Windows uploads a ZIP. Downloads appear under
the run's **Artifacts** section and are retained for 14 days.

The native archives are also available to embedders in the **Browser CI** run.
Use **Servo Native Assets** for a standalone manual build or a `native-v*` tag.

The GTK3 build uses standard Flutter stable on `ubuntu-latest`. The GTK4 build
uses the public Flutter GTK4 fork and precompiled engine artifacts:

- Flutter fork revision: `dbffa60d521e3c3a9580b47df00fcd4875d493a8`
- Prebuilt engine: `89573e968cbf3febdf4f07189cc2bef6cbef830b`
- FVM: `4.2.0`
- Runner: Ubuntu 26.04, x86_64

Ubuntu 26.04 is a [supported GitHub-hosted runner label](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).
Some versions of actionlint still require ignoring its unknown-label warning
for this runner when validating locally.

No local Flutter/Servo/Surfman checkout is required on the runner. The package's
Rust toolchain and public Servo/Surfman pins remain authoritative. Native build
jobs install Python 3.11 for Servo's generated bindings and compile Rust in
release mode. Common Flutter assets use Flutter's usual storage; the custom
storage URL is scoped to the engine setup.

The engine installer verifies debug/profile/release archive contents and GTK
linkage. The bundle check requires AOT assets, the selected GTK version, the native Servo entry
point, and resolved ELF dependencies. A native probe exercises local HTML,
Unicode composition, context menus, and stale-response rejection under Xvfb
without screenshots.

GTK3 and GTK4 packages install side by side as `flutter-servo-browser-gtk3`
and `flutter-servo-browser-gtk4`, each with a command and desktop entry. RPMs
store their private bundles under `/usr/lib64` and DEBs under `/usr/lib`.
Packaging rewrites build-tree RUNPATHs in a temporary copy and derives system
dependencies from the binaries. The packages require distributions with system
libraries compatible with their build runner. GPU sharing remains opt-in through
`FLUTTER_SERVO_GPU_TEXTURES=1`.

Build packages locally from existing release bundles:

```bash
bash tools/build_browser_rpm.sh --gtk gtk3 --version 0.1.0
bash tools/build_browser_deb.sh --gtk gtk4 --version 0.1.0
```

RPM packaging requires an x86_64 Linux host with `rpm` and `rpmbuild`. DEB
packaging requires Debian or Ubuntu x86_64 with `dpkg-dev` and the system
libraries used by the bundle. Both require `patchelf` and `binutils`. Use
`--bundle-dir` and `--out-dir` to select other paths.

`v*` tags trigger **Browser Release**, which runs the same Flutter, Rust, and
packaging checks as CI before building the Linux and Windows bundles and both
GTK variants' RPMs and DEBs. The release workflow can also
be run manually with an existing tag. It resolves the tag once, tests and
builds that commit, and verifies that the tag still names that commit before
publishing. Build provenance records the checked-out commit, including when a
manual release targets a tag different from the workflow's branch.

The browser and embedding package use the checked-in MIT licenses. No
repository license variable is needed to publish a release.

## Dart Package Releases

Publish the first version (`0.1.2`) manually from `packages/flutter_servo`
using `flutter pub publish`. First review `flutter pub publish --dry-run`:
the exact Flutter Rust Bridge pins intentionally produce warnings because
the generated bridge requires a matching runtime.
Then enable GitHub Actions publishing on the package's pub.dev Admin tab:
repository `richyo-codes/flutter_servo`, tag pattern `dart-v{{version}}`, and
required GitHub environment `pub.dev`. Create that environment in GitHub
before publishing, and protect it with reviewers if available.

For subsequent versions, update the package pubspec and changelog, then push
the matching `dart-vX.Y.Z` tag. This publishes the Dart package only. Browser
bundles still use `vX.Y.Z` and native archives use `native-vX.Y.Z`.
The package builds Servo from source by default. Set `prebuilt_native_tag`
to use a matching GitHub release without Cargo, as described in
[Native Servo Builds](native-builds.md).

Workflow files are in `.github/workflows/`; they run when this repository is
hosted or mirrored on GitHub with Actions enabled. No remote workflow has been
dispatched by adding these files locally.
