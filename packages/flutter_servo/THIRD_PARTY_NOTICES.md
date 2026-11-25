# Third-Party Notices

The Flutter Servo WebView project is licensed under the [MIT License](LICENSE).
Third-party code retains its own licenses.

## Servo

The Linux and Windows backends embed [Servo](https://github.com/servo/servo),
a web engine distributed under the Mozilla Public License 2.0 (MPL-2.0).
The pinned dependency is built from a [Servo fork at revision
`18ead82`](https://github.com/richyo-codes/servo/tree/18ead822e67b7660f7ee46cd03e6780940d7cc34).
See that revision for the [Servo license text](https://github.com/richyo-codes/servo/blob/18ead822e67b7660f7ee46cd03e6780940d7cc34/LICENSE),
source code, and notices for bundled components. The MIT license for the Flutter
integration does not replace those terms.

Flutter Servo WebView is an independent project and is not affiliated with or
endorsed by the Servo project. The Android and iOS fallback uses the system
WebView rather than Servo.

This notice is not an exhaustive inventory of transitive dependencies.
