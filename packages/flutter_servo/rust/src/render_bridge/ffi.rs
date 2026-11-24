//! C ABI for the desktop render session. The host owns session handles and
//! must call session APIs on the owning thread, except for wake callbacks.

use std::ffi::{c_void, CStr};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::null_mut;

use euclid::Scale;
use servo::{InputEvent, KeyState, MouseButton, MouseButtonAction, RgbaImage};

use super::{log_elapsed_ms, ProxyOverrides, ServoRenderSession};
use crate::frame_size::FrameSize;

fn guard<T>(operation: &str, fallback: T, call: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|_| {
        render_log!("flutter_servo: {operation} panicked");
        fallback
    })
}

fn optional_c_string(ptr: *const c_char) -> Option<String> {
    c_string(ptr).map(|value| value.to_owned())
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_new(
    http_proxy_uri: *const c_char,
    https_proxy_uri: *const c_char,
    no_proxy: *const c_char,
) -> *mut c_void {
    render_log!("flutter_servo: ffi session_new invoked");
    let proxy_overrides = ProxyOverrides {
        http_proxy_uri: optional_c_string(http_proxy_uri),
        https_proxy_uri: optional_c_string(https_proxy_uri),
        no_proxy: optional_c_string(no_proxy),
    };
    match std::panic::catch_unwind(|| ServoRenderSession::new(proxy_overrides)) {
        Ok(Ok(session)) => {
            render_log!("flutter_servo: ffi session_new success");
            Box::into_raw(Box::new(session)).cast()
        }
        Ok(Err(error)) => {
            render_log!("flutter_servo: ffi session_new error: {error}");
            null_mut()
        }
        Err(_) => {
            render_log!("flutter_servo: ffi session_new panicked");
            null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_free(session: *mut c_void) {
    if !session.is_null() {
        guard("session teardown", (), || {
            drop(Box::from_raw(session.cast::<ServoRenderSession>()));
        });
    }
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_set_viewport_scale(
    session: *mut c_void,
    display_scale: f32,
    page_zoom: f32,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_mut() else {
        return false;
    };
    if !(0.5..=8.0).contains(&display_scale) || !(0.5..=3.0).contains(&page_zoom) {
        return false;
    }
    if let Some(webview) = &session.webview {
        if session.display_scale != display_scale {
            webview.set_hidpi_scale_factor(Scale::new(display_scale));
        }
        if session.page_zoom != page_zoom {
            webview.set_page_zoom(page_zoom);
        }
    }
    if session.display_scale != display_scale || session.page_zoom != page_zoom {
        session.display_scale = display_scale;
        session.page_zoom = page_zoom;
        session.delegate.mark_frame_dirty();
    }
    true
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_set_url(
    session: *mut c_void,
    url: *const c_char,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_mut() else {
        return false;
    };
    let Some(url) = c_string(url) else {
        return false;
    };
    session.set_url(url)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_set_html(
    session: *mut c_void,
    html: *const c_char,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_mut() else {
        return false;
    };
    let Some(html) = c_string(html) else {
        return false;
    };
    session.set_html(html)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_go_back(session: *mut c_void) -> bool {
    session
        .cast::<ServoRenderSession>()
        .as_mut()
        .is_some_and(ServoRenderSession::go_back)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_go_forward(session: *mut c_void) -> bool {
    session
        .cast::<ServoRenderSession>()
        .as_mut()
        .is_some_and(ServoRenderSession::go_forward)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_reload(session: *mut c_void) -> bool {
    session
        .cast::<ServoRenderSession>()
        .as_mut()
        .is_some_and(ServoRenderSession::reload)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_is_animating(session: *const c_void) -> bool {
    session
        .cast::<ServoRenderSession>()
        .as_ref()
        .is_some_and(ServoRenderSession::is_animating)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_load_progress(session: *const c_void) -> u8 {
    session
        .cast::<ServoRenderSession>()
        .as_ref()
        .map_or(0, ServoRenderSession::load_progress)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_poll(session: *const c_void) -> bool {
    session
        .cast::<ServoRenderSession>()
        .as_ref()
        .is_some_and(ServoRenderSession::poll)
}

/// The callback must only enqueue work and must not call back into Servo.
/// Clear it before destroying its context or the host's message window.
#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_set_wake_callback(
    session: *const c_void,
    callback: Option<crate::wake_callback::Callback>,
    context: *mut c_void,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    session.wake_callback.set(callback, context);
    if callback.is_some() {
        session.wake_callback.notify();
    }
    true
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_wake_fd(session: *const c_void) -> i32 {
    session
        .cast::<ServoRenderSession>()
        .as_ref()
        .and_then(|session| session.wake_signal.clone_receiver_fd().ok())
        .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_get_navigation_state(
    session: *const c_void,
    url_out: *mut c_char,
    url_out_len: usize,
    can_go_back_out: *mut bool,
    can_go_forward_out: *mut bool,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    let Some((url, can_go_back, can_go_forward)) = session.navigation_state() else {
        return false;
    };
    if url_out.is_null()
        || url_out_len == 0
        || can_go_back_out.is_null()
        || can_go_forward_out.is_null()
    {
        return false;
    }
    let bytes = url.as_bytes();
    let copy_len = bytes.len().min(url_out_len - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), url_out.cast::<u8>(), copy_len);
    *url_out.add(copy_len) = 0;
    *can_go_back_out = can_go_back;
    *can_go_forward_out = can_go_forward;
    true
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_notify_mouse_move(
    session: *mut c_void,
    x: i32,
    y: i32,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    session.send_mouse_move(x, y)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_notify_mouse_button(
    session: *mut c_void,
    x: i32,
    y: i32,
    button: u8,
    is_down: bool,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    let button = match button {
        0 => MouseButton::Primary,
        1 => MouseButton::Auxiliary,
        2 => MouseButton::Secondary,
        3 => MouseButton::Back,
        4 => MouseButton::Forward,
        value => MouseButton::Other(value as u16),
    };
    let action = if is_down {
        MouseButtonAction::Down
    } else {
        MouseButtonAction::Up
    };
    session.send_mouse_button(x, y, button, action)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_notify_mouse_leave_viewport(
    session: *mut c_void,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    session.send_mouse_leave_viewport()
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_notify_mouse_wheel(
    session: *mut c_void,
    x: i32,
    y: i32,
    delta_x: i32,
    delta_y: i32,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    session.send_mouse_wheel(x, y, delta_x, delta_y)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_notify_key_event(
    session: *mut c_void,
    key_label: *const c_char,
    character: *const c_char,
    is_down: bool,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    let Some(key_label) = c_string(key_label) else {
        return false;
    };
    let character = c_string(character).unwrap_or("");
    let key_state = if is_down {
        KeyState::Down
    } else {
        KeyState::Up
    };
    session.send_keyboard_event(key_label, character, key_state)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_paint(
    session: *mut c_void,
    width: u32,
    height: u32,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_mut() else {
        return false;
    };
    let Some(size) = FrameSize::new(width, height) else {
        return false;
    };
    guard("paint", false, || session.paint(&size))
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_take_control_event(
    session: *mut c_void,
) -> *mut c_char {
    guard("take control event", null_mut(), || {
        take_control_event(session)
    })
}

unsafe fn take_control_event(session: *mut c_void) -> *mut c_char {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return null_mut();
    };
    let control_event = session
        .cookie_clear_done
        .take()
        .map(|id| serde_json::json!({"type":"cookiesCleared","id":id}).to_string())
        .or_else(|| {
            session
                .delegate
                .cursor_update
                .take()
                .map(|cursor| serde_json::json!({"type": "cursor", "cursor": cursor}).to_string())
                .or_else(|| session.delegate.controls.borrow_mut().take_event())
        });
    control_event
        .or_else(|| session.delegate.accessibility.borrow_mut().take_event())
        .and_then(|event| std::ffi::CString::new(event).ok())
        .map_or(null_mut(), std::ffi::CString::into_raw)
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_control_event_free(event: *mut c_char) {
    if !event.is_null() {
        drop(std::ffi::CString::from_raw(event));
    }
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_control_response(
    session: *mut c_void,
    response: *const c_char,
) -> bool {
    guard("control response", false, || {
        control_response(session, response)
    })
}

unsafe fn control_response(session: *mut c_void, response: *const c_char) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    let Some(response) = c_string(response) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(response) else {
        return false;
    };
    match value["type"].as_str() {
        Some("requireNavigationPolicy") => {
            session.delegate.host_navigation_policy.set(true);
            true
        }
        Some("verifyKioskConfiguration") => {
            let Some(wanted) = value["origins"].as_array() else {
                return false;
            };
            let Some(actual) = session.delegate.allowed_origins.as_ref() else {
                return false;
            };
            let expected: Option<std::collections::HashSet<_>> = wanted
                .iter()
                .map(|item| {
                    let origin = item.as_str()?;
                    let parsed = super::parse_origins(origin).ok()?;
                    if parsed.len() != 1 || origin.contains(',') {
                        return None;
                    }
                    parsed.into_iter().next()
                })
                .collect();
            session.ephemeral_storage
                && expected.is_some_and(|expected| expected == actual.iter().cloned().collect())
        }
        Some("navigationDecision") => value["id"].as_u64().is_some_and(|id| {
            session
                .delegate
                .controls
                .borrow_mut()
                .decide_navigation(id, value["allow"].as_bool() == Some(true))
        }),
        Some("filePicker") => value["id"].as_u64().is_some_and(|id| {
            session
                .delegate
                .controls
                .borrow_mut()
                .respond_picker(id, &value["paths"])
        }),
        Some("scriptDialog") => value["id"].as_u64().is_some_and(|id| {
            session.delegate.controls.borrow_mut().respond_dialog(
                id,
                value["accept"].as_bool() == Some(true),
                &value["value"],
            )
        }),
        Some("clearCookiesConfirmed") => {
            let (Some(servo), Some(id)) = (session.servo.as_ref(), value["id"].as_u64()) else {
                return false;
            };
            if session.cookie_clear_done.get().is_some()
                || session.cookie_clear_pending.replace(true)
            {
                return false;
            }
            let pending = session.cookie_clear_pending.clone();
            let done = session.cookie_clear_done.clone();
            servo
                .site_data_manager()
                .clear_cookies(Some(Box::new(move || {
                    pending.set(false);
                    done.set(Some(id));
                })));
            true
        }
        Some("clearSiteData") => {
            let (Some(servo), Some(site)) = (session.servo.as_ref(), value["site"].as_str()) else {
                return false;
            };
            if !valid_site_name(site) {
                return false;
            }
            servo.site_data_manager().clear_site_data(
                &[site],
                servo::StorageType::Cookies
                    | servo::StorageType::Local
                    | servo::StorageType::Session,
            );
            true
        }
        Some("supportsValidatedSiteClear") => session.servo.is_some(),
        Some("accessibilityEnabled") => {
            let Some(enabled) = value["enabled"].as_bool() else {
                return false;
            };
            session.accessibility_enabled.set(enabled);
            let root = session
                .webview
                .as_ref()
                .filter(|_| !session.delegate.crashed.get())
                .and_then(|webview| webview.set_accessibility_active(enabled));
            session.delegate.accessibility.borrow_mut().set_root(root);
            true
        }
        Some("accessibilityAction") => {
            if !session.accessibility_enabled.get() || session.delegate.crashed.get() {
                return false;
            }
            let Some(servo) = session.servo.as_ref() else {
                return false;
            };
            let Some(action) = session.delegate.accessibility.borrow().action(&value) else {
                return false;
            };
            servo.forward_accessibility_action(action);
            true
        }
        Some("contextMenu") => {
            let Some(id) = value["id"].as_u64() else {
                return false;
            };
            session.delegate.controls.borrow_mut().respond(
                id,
                value["index"]
                    .as_u64()
                    .and_then(|index| usize::try_from(index).ok()),
            )
        }
        Some("composition") => {
            if session.delegate.crashed.get()
                || !value["id"]
                    .as_u64()
                    .is_some_and(|id| session.delegate.controls.borrow().ime_matches(id))
            {
                return false;
            }
            let Some(webview) = session.webview.as_ref() else {
                return false;
            };
            let state = match value["state"].as_str() {
                Some("start") => servo::CompositionState::Start,
                Some("update") => servo::CompositionState::Update,
                Some("end") => servo::CompositionState::End,
                _ => return false,
            };
            let Some(text) = value["text"].as_str() else {
                return false;
            };
            webview.notify_input_event(InputEvent::Ime(servo::ImeEvent::Composition(
                servo::CompositionEvent {
                    state,
                    data: text.to_owned(),
                },
            )));
            true
        }
        _ => false,
    }
}

fn valid_site_name(site: &str) -> bool {
    let Ok(host) = url::Host::parse(site) else {
        return false;
    };
    if host.to_string() != site {
        return false;
    }
    match host {
        url::Host::Domain(domain) => {
            domain.len() <= 253
                && domain.split('.').all(|label| {
                    !label.is_empty()
                        && label.len() <= 63
                        && !label.starts_with('-')
                        && !label.ends_with('-')
                        && label
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                })
        }
        _ => true,
    }
}

#[cfg(test)]
mod site_name_tests {
    use super::valid_site_name;

    #[test]
    fn accepts_only_canonical_site_identifiers() {
        for site in [
            "example.com",
            "127.0.0.1",
            "localhost",
            "[::1]",
            "xn--bcher-kva.example",
        ] {
            assert!(valid_site_name(site), "{site}");
        }
        for site in [
            "",
            " ",
            "EXAMPLE.COM",
            "https://example.com",
            "example.com:443",
            "site.example/path",
            "example.com.",
            "*.example.com",
            "a..b",
            "-invalid.example",
            "user@example.com",
            "127.1",
            "bad_name",
        ] {
            assert!(!valid_site_name(site), "{site}");
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_focus_webview(session: *mut c_void) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    session.focus_webview();
    true
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_blur_webview(session: *mut c_void) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
        return false;
    };
    session.blur_webview();
    true
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_render_rgba(
    session: *mut c_void,
    width: u32,
    height: u32,
    out_rgba: *mut u8,
    out_len: usize,
) -> bool {
    let Some(session) = session.cast::<ServoRenderSession>().as_mut() else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        session.render_rgba(width, height, out_rgba, out_len)
    }))
    .unwrap_or_else(|_| {
        render_log!("flutter_servo: rust render panicked");
        false
    })
}

struct ExportedFrame(RgbaImage);

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_session_render_frame(
    session: *mut c_void,
    width: u32,
    height: u32,
    data_out: *mut *const u8,
    len_out: *mut usize,
) -> *mut c_void {
    let Some(session) = session.cast::<ServoRenderSession>().as_mut() else {
        return null_mut();
    };
    if data_out.is_null() || len_out.is_null() {
        return null_mut();
    }
    let Some(size) = FrameSize::new(width, height) else {
        return null_mut();
    };
    guard("render frame", None, || session.render_image(&size)).map_or(null_mut(), |image| {
        let frame = Box::new(ExportedFrame(image));
        *data_out = frame.0.as_raw().as_ptr();
        *len_out = frame.0.as_raw().len();
        Box::into_raw(frame).cast()
    })
}

#[no_mangle]
pub unsafe extern "C" fn flutter_servo_frame_free(frame: *mut c_void) {
    if !frame.is_null() {
        drop(Box::from_raw(frame.cast::<ExportedFrame>()));
    }
}

fn c_string<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }

    unsafe { CStr::from_ptr(ptr).to_str().ok() }
}
