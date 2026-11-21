# Servo ancestor origins panic on Windows

A Windows release run over RDP using Servo revision `18ead822e67b7660f7ee46cd03e6780940d7cc34`
completed several navigations. About 62 minutes after the first Rust bridge log,
the app logged a resize to 3528x1487 followed by a pending navigation. During
that navigation, `Script#71` panicked in
`components/script/dom/window/location.rs:630` with
`Must always have ancestor origins initialized`. The session subsequently
logged shutdown start and completion.

At this revision, `Location::AncestorOrigins` expects the document's ancestor
origins list to exist after its origin checks. The panic indicates that this
invariant failed. The expected behavior is for the accessor to return the
appropriate list or DOM exception and for the script thread to remain usable.

The URL, frame hierarchy, stack trace, and whether shutdown was user-initiated
are unknown. The preceding resize, frame preparation messages, and RDP session
are observations, with no established causal link. No minimal reproduction or
workaround has been confirmed.

Servo introduced the accessor in [servo/servo#46056](https://github.com/servo/servo/pull/46056).
A public search did not identify a matching fix. If the panic recurs, capture
the URL or a shareable local page, navigation sequence, and a stack trace with
`RUST_BACKTRACE=1`. Check the same sequence on current upstream Servo before
filing a report or changing the pinned fork.
