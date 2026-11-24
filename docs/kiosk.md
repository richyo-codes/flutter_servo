# Embedding in a kiosk

**Build from the current source to try these controls.** The released
`native-v0.1.2` binary predates the origin policy. Setting the environment
variable with that binary does not enable the restriction.

Use `FlutterServoBackend.auto.hostControls()` to decide which controls to
offer on this platform. For example, `FlutterServoHostControl.downloadNotification`
is available on Android WebView, while `FlutterServoHostControl.ephemeralLaunch`
describes a desktop launch option. This query describes the source adapter;
it does not inspect the native binary, grant permissions, or certify a kiosk.

## Restrict desktop navigation

Set the policy in the environment of the process that launches your Flutter
app. For example, on Linux:

```sh
FLUTTER_SERVO_ALLOWED_ORIGINS='https://display.example,https://login.example' ./my_kiosk
```

On Windows PowerShell:

```powershell
$env:FLUTTER_SERVO_ALLOWED_ORIGINS = 'https://display.example,https://login.example'
.\my_kiosk.exe
```

The desktop session reads the list at creation. An entry covers all paths on
one HTTPS origin. It does not include sibling domains, subdomains, or another
port. Leave the variable unset for ordinary browsing. An empty list permits
no host URL loads; malformed entries prevent session creation. Raw HTML is
not an allowlisted origin, so use a URL rather than the HTML constructor.

The check applies to host loads and requests Servo sends to its navigation
delegate. It is **not an outbound firewall**: scripts, images, fetch requests,
and other subresources are not confined by origin. In protected desktop mode,
Servo's WebView interceptor cancels HTTP redirects, including same-origin and
subresource redirects: the pinned API identifies the redirect but supplies the
first URL in its chain, not the destination. Use direct URLs. A blocked
main-frame redirect reports `redirect-blocked`. This does not cover worker
requests outside the WebView interceptor. The mobile system WebView does not
enforce this variable.

## Observe a page

On mobile, setting `allowNavigation` disables the controller and static
`goBack`, `goForward`, and `reload` commands: the WebView cannot preflight
the request it would replay. To refresh, issue a fresh URL load by incrementing
the surface's `reloadRevision`; the URL goes through the host policy again.

On a desktop Servo surface or a mobile WebView, install a synchronous decision:

```dart
allowNavigation: (uri, isMainFrame) =>
    uri.scheme == 'https' && uri.userInfo.isEmpty &&
    uri.origin == 'https://display.example',
```

This checks host URL loads and navigation requests reported by the platform.
A throwing callback denies the request. Raw HTML loads are refused while a
policy is installed. Keep the callback side-effect free: one URL can be
checked at more than one stage. It does not filter subresources or retroactively
unload an existing page. On desktop a matching native plugin and Rust library
are required. The host approves the initial URL, then `setPolicyUrl` installs
native interception before loading it. Servo does not identify which frame
requested a navigation: `isMainFrame` is null for its delegate requests. A
configured native origin allowlist still takes precedence. Mount a new surface
to switch between protected and unrestricted desktop modes.

For external destinations, pass `policy.allows` as the callback. For example:

```dart
final policy = FlutterServoNavigationPolicy(
  decide: (uri, frame) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      return FlutterServoNavigationDecision.block;
    }
    if (uri.origin == 'https://display.example') {
      return FlutterServoNavigationDecision.navigate;
    }
    return uri.origin == 'https://support.example' && frame != false
        ? FlutterServoNavigationDecision.handOff
        : FlutterServoNavigationDecision.block;
  },
  onHandOff: (uri, frame) => showHostConfirmation(uri),
);
```

Handoff blocks the navigation inside the surface. It does not establish that
the user clicked, start another application, or authorize a redirect. Require
a fresh user action before opening any external destination.

Attach a controller and callbacks to the same surface:

```dart
FlutterServoSurface.url(
  controller: controller,
  content: 'https://display.example/welcome',
  fallback: const SizedBox.shrink(),
  onTitleChanged: (title) => updateCaption(title ?? ''),
  onLoadProgressChanged: updateLoadIndicator,
  onError: showLoadError,
)
```

These are notifications, not authorization callbacks. Treat the page title as
untrusted. Mobile surfaces can also use `onLoadPercentChanged` for the OS
WebView's estimate. A 100% estimate is not a successful load; use the load
milestones and error callback for state transitions. Servo does not emit a
numeric estimate.

Desktop blocks auxiliary windows and can notify the host with
`onPopupBlocked`. The pinned Servo API does not expose the destination URL;
the notification does not open another view or launch an external application.
Repeated popup attempts can produce a single notification. Mobile
samples the title while updating navigation state, rather than observing every
script-driven title change.

## Device access

On Android WebView, `allowGeolocation` receives the requesting HTTPS origin
from the platform prompt. For example:
`allowGeolocation: (origin) => origin.toString() == 'https://display.example'`.
The default is deny. Exceptions deny the request, grants are not retained across
pages, and the host still needs the relevant OS permission. This callback is
not a general permission broker and does not enable camera or microphone use.

Servo permission requests and the generic mobile WebView resource prompt
do not expose a trustworthy requesting origin in the pinned APIs. The adapter
denies these requests; `onPermissionDenied` reports resource names for host
UI or audit logs. Do not infer permission identity from the top-level URL.

Android file uploads cancel unless the host supplies `onPickUploadFiles`.
Use a user-visible system document picker and return only the selected
`content://` URIs. The requested MIME types are hints, not evidence of a
trusted requester. Android does not identify the requesting frame here: never
automatically choose a file based on the address bar. Save and live capture
requests are not supported by this callback.

On desktop, `onPickUploadFiles` must return local file URIs from a user-visible
picker (no network authorities). Servo consumes a selection only for the
outstanding picker ID; cancellation, navigation, and teardown invalidate it.
The embedder does not pass previously selected paths back automatically.

Android download starts are intercepted before handing anything to a download
manager. `onDownloadRequested` receives the HTTPS destination, MIME hint,
and optional byte count on the requesting surface. Without a callback nothing
is saved. No cookie headers or server-supplied filenames are forwarded.
The notification identifies the surface, not the initiating frame's origin.
Do not authorize a download based on the address bar or assume navigation
approval covers downloads. If the kiosk does not need downloads, leave the
callback unset. If the host fetches the file itself, check the destination
against its download policy before the first request and at every redirect.
Enforce a byte limit while reading; the reported length is not a limit.
Avoid logging the URL because its query may contain signed tokens.

To test notification delivery on Android, use an HTTPS endpoint you control
that returns `Content-Disposition: attachment` without redirecting:

```sh
cd packages/flutter_servo/example
flutter run -d "$ANDROID_DEVICE" -t tool/mobile_webview_probe.dart \
  --dart-define="PROBE_ATTACHMENT_URL=$ATTACHMENT_URL"
```

Tap **Test attachment** within 30 seconds. Look for `ok=true` and
`download=true` in the Flutter log. The probe checks the exact destination
without fetching or saving the file in Dart.

## End a visitor session

For a source-built desktop renderer, set `FLUTTER_SERVO_EPHEMERAL=1` before
launch. Each new Servo engine uses temporary storage and no configured profile
directory. Navigating, reloading, or changing the Flutter controller does not
start a new engine. Terminate the visitor's browser process between users.
Unset or `0` selects Servo defaults; other values prevent session creation.
This option does not configure the Android/iOS system WebView.

This mode does not promise diskless operation or secure erasure. Servo uses
temporary directories for some stores, and a killed process can leave files
behind. Use a disposable OS profile or temporary filesystem if this matters.

| Controller operation | Scope |
| --- | --- |
| `await controller.clearCookies()` | Clears the backend's cookie store, not just this surface. Desktop waits for Servo to confirm both cookie jars; a timeout or closed surface is an error, not confirmation. |
| `await controller.clearSiteData(site)` | Desktop Servo only: cookies and local/session web storage for the supplied Servo site name. It does not clear HTTP cache, IndexedDB, or files. |

Neither operation implements private browsing or guarantees separation between
visitors. Do not hand a kiosk to the next visitor on the strength of these
calls alone. If isolation is required today, give visitors disposable OS
profiles and enforce network and filesystem access outside the browser process.

Pass a canonical lowercase ASCII site name (for example, `example.com`
or a punycode name) or a canonical IP literal, not a URL with a
scheme, port, or path. Unlike `clearCookies()`, `clearSiteData()` acknowledges
the native request; it does not return a deletion receipt. The Linux native
regression reads the page again to verify the effect:

```sh
python3 tools/test_servo_ephemeral.py packages/flutter_servo/rust/target/debug/librust_lib_flutter_servo.so
```

## Deployment checks

On Linux, run this from your launcher with the **same environment and native
library** as the browser. Supply expected origins from your deployment policy,
not by copying the environment variable at runtime:

```sh
python3 tools/verify_servo_kiosk.py "$bundle/lib/librust_lib_flutter_servo.so" \
  --origin https://display.example --origin https://login.example || exit 1
```

The probe creates a separate session without loading a page. It requires
temporary storage, no profile directory, and an exact origin-set match.
Omit all `--origin` arguments to require a configured, empty allowlist.
This checks configuration, not outbound network confinement.

Test the exact packaged binary, not just the development build. Verify that an
allowed URL loads, a different origin and port are rejected, and a malformed
policy prevents startup. Test redirects and outbound subresource requests
against your network policy. A missing variable means unrestricted navigation,
so validate the launcher configuration before starting an unattended kiosk.

Per-navigation host decisions, popup and external-launch policy, ephemeral
sessions, permission prompts, file pickers, and downloads are not yet exposed
as a complete host-controlled API. Do not assume that a missing callback is a
security boundary.
## JavaScript dialogs

Desktop Servo surfaces suppress page dialogs by default. For trusted pages,
set `enableJavaScriptDialogs: true` to show `alert()`, `confirm()`, and
`prompt()` as Flutter modals in the existing window. Outstanding dialogs
are canceled on navigation or teardown; unanswered modals time out.
`window.open()` remains blocked. Flutter's preview multi-window API is a
future option for surfacing auxiliary Servo WebViews, not a dependency here.
