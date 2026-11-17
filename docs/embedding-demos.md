# Embedding demos

Run the existing browser example, then open **Embedding demos** (the flask icon
beside bookmarks). All four examples use the same native Servo surface. Their
HTML lives in `packages/flutter_servo/example/assets/demos/` and can also be
opened in another browser for comparison. Switch to the phone viewport to test
responsive content; this does not establish Android backend support.

| Demo | Test |
| --- | --- |
| Login / consent | Type a fictional display name, Tab to Continue, allow or deny consent, reset. Verify focus and DOM updates. No credentials or authentication. |
| License notices | Search, clear the filter, expand notices, select and copy text. Notices are fictional, not a license inventory. |
| Documentation | Follow anchors, scroll, select code, type scratch notes, expand troubleshooting. Entirely offline. |
| Video playback | Choose MP4 or WebM, explicitly play, pause, seek and resize. Inspect capability hints, media events and errors. Requires network access. |

## Authentication boundary

The consent example is a local interaction fixture, **not an OAuth client**.
It makes no authentication requests and stores no credentials. Real native-app
OAuth should use an external user agent with authorization code + PKCE, verified
state, and an exactly validated redirect. Embedded authorization is disallowed
by [RFC 8252, section 8.12](https://www.rfc-editor.org/rfc/rfc8252#section-8.12).
A production example needs a registered client, redirect integration and a
system-browser launch path; do not turn this mock into a password collector.

## Media boundary

The player tests HTML media behavior, not a Flutter video plugin. It loads MDN's
flower sample (see [MDN video documentation](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/video)).
The current Servo dependency disables default features and does not enable
`media-gstreamer`; actual playback may therefore be unavailable. This demo does
not silently enable that backend or introduce its packaging dependencies.
`canPlayType` is only a hint: successful playback requires advancing frames,
working pause/seek, and an absence of media errors. Test media support separately
on each target. DRM, audio output, fullscreen and hardware decoding are not
validated by these fixtures.

## Verification

From `packages/flutter_servo/example`, run:

```sh
flutter test test/browser_page_test.dart
```

Widget tests verify that every menu choice loads its bundled HTML through the
native method channel at a phone width, alongside existing browser tests. They
mock the native renderer and do not prove JavaScript, video decoding, texture
presentation or real authentication. Perform the interactions above on-device,
including switching demos while media is active and closing the app afterward.
