# Windows builds

The experimental Windows x64 backend embeds Servo in a Flutter pixel-buffer
texture. It uses the standard Flutter Windows engine. GTK and the custom Linux
Flutter SDK are not needed.

Servo tries an ANGLE D3D11 hardware context first and falls back to WARP if
context creation fails. The `Servo graphics` startup line identifies the
selected renderer. To force WARP for comparison, set
`$env:FLUTTER_SERVO_GPU_TEXTURES = '0'` before launching the browser or native
probe. Remove that environment variable to restore automatic selection.

Frames are read back to RGBA and passed to Flutter with an explicit release
callback. Servo wakeups post
coalesced messages to the platform thread; a 16 ms timer runs only during
animation. Direct D3D texture sharing is not implemented yet.

## Prerequisites

Use Windows 10/11 x64 with:

- Flutter stable with Windows desktop support (`flutter doctor -v`).
- Visual Studio 2022, Desktop development with C++, MSVC v143, C++ ATL, and
  Windows SDK 10.0.19041 or newer.
- LLVM/Clang with `libclang.dll` (CI uses LLVM 20.1).
- Rustup, Git, CMake, and `uv` on PATH.
- PowerShell 7 (`pwsh`) for the build script.
- Windows Developer Mode enabled so Flutter can create plugin symlinks.

Use **Developer PowerShell for VS 2022** with the x64 compiler environment.
If it opens Windows PowerShell 5, run `pwsh` there to inherit the compiler
environment in PowerShell 7.
Keep the checkout path short, for example `C:\src\flutter-servo-browser`.
If Cargo reports `path too long` while fetching Servo, shorten its dependency
cache as well. Set `$env:CARGO_HOME = 'C:\ch'` before building, as Windows CI
does. This changes the dependency checkout location independently of the
Native Assets build-output path.
The first build compiles Servo and SpiderMonkey and can take substantial time
and memory. The scripts default to two Cargo jobs; reduce `CARGO_BUILD_JOBS`
to `1` if necessary.

Servo's upstream setup is documented in the
[Windows build guide](https://book.servo.org/building/windows.html).

## Build and run

From the repository root:

```powershell
.\tools\build_windows.ps1 -Configuration Release -Probe -Run
```

The script downloads upstream MozTools 4.0 into `.dart_tool/windows-deps`, installs
Python 3.11 through `uv`, selects the package's Rust toolchain, and builds the
example. The Native Assets hook enables Servo and bundles its `libEGL.dll` and
`libGLESv2.dll` dependencies. No local Servo checkout is required.

Packaging requires both ANGLE DLLs from one Cargo build output. If the hook
reports multiple complete pairs, clean the native-assets Cargo output directory
named in the error and rebuild. It deliberately refuses to guess between cached
versions or combine DLLs from different builds.

The native probe checks loading, wake notifications, rendered pixel colors,
mouse clicks, resizing, and shutdown using the bundled Rust DLL. It has a
60-second process timeout so a shutdown hang fails the check. It does not
validate Flutter texture presentation or IME interaction; test those in the app.

The output is:

```text
packages/flutter_servo/example/build/windows/x64/runner/Release/
```

Run `flutter_servo_example.exe` from that directory. Distribute the entire
directory, including DLLs and `data/`, not just the executable. Build and probe
logs are in `logs/windows*.log`.

For a debug Flutter session:

```powershell
.\tools\setup_windows.ps1
cd packages\flutter_servo\example
flutter run -d windows
```

The Rust hook defaults to an optimized Rust build even for Flutter debug mode.
The initial target is x64; ARM64 and Windows cross-compilation from Linux are
not supported by this build script.

## Interactive checks

- Load local HTML and an HTTPS URL; the page should appear without mouse input.
- Scroll, select text, edit a page input, and try keyboard/IME composition.
- Exercise Ctrl+L, navigation, reload, clipboard, and the page context menu.
- Resize the window and move it between monitors with different DPI settings.
- Close during a load and after several navigations; check for hangs or crashes.

The existing Servo WindowProxy workaround remains pinned. It prevents a known
panic but is not a demonstrated root-cause fix. Windows runtime behavior,
especially IME, clipboard, and shutdown, still needs validation on Windows.

## CI

`Build Windows Browser` can run manually or through `Browser CI` and
`Browser Release`. It builds a release bundle on `windows-2022`, runs the native
probe, and uploads a versioned ZIP plus build logs. Tagged browser releases
include the ZIP when release publishing is enabled. Browser CI and Browser
Release consume the Windows native archive built earlier in the same run.
A standalone Windows browser run builds Servo from source.
