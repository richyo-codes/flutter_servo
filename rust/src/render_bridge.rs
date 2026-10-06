use std::ffi::{c_void, CStr};
use std::os::raw::c_char;
use std::slice;

const BYTES_PER_PIXEL: usize = 4;
#[cfg(not(feature = "servo-engine"))]
const ALPHA: u8 = 255;

#[cfg(feature = "servo-engine")]
mod imp {
    use std::cell::Cell;
    use std::panic::{catch_unwind, AssertUnwindSafe};
    use std::ptr::null_mut;
    use std::rc::Rc;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };
    use std::time::{Duration, Instant};

    use dpi::PhysicalSize;
    use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
    use servo::{DeviceIntPoint, DeviceIntRect, DeviceIntSize};
    use servo::{
        DevicePoint, EventLoopWaker, InputEvent, Key, KeyState, LoadStatus, MouseButton,
        MouseButtonAction, MouseButtonEvent, MouseLeftViewportEvent, MouseMoveEvent, NamedKey,
        Preferences, RenderingContext, RgbaImage, Servo, ServoBuilder, SoftwareRenderingContext,
        WebView, WebViewBuilder, WebViewDelegate, WheelDelta, WheelEvent, WheelMode,
    };
    use url::Url;

    use super::{c_char, c_string, c_void, slice, BYTES_PER_PIXEL};

    const DEFAULT_HTML: &str = r#"<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <style>
      :root {
        color-scheme: light;
        font-family: sans-serif;
      }

      body {
        margin: 0;
        padding: 32px;
        background: linear-gradient(180deg, #f6f8f4 0%, #ecefe7 100%);
        color: #1f2a1d;
      }

      main {
        max-width: 720px;
      }

      h1 {
        margin: 0 0 12px;
        font-size: 36px;
      }

      p {
        margin: 0 0 16px;
        line-height: 1.5;
      }

      input {
        width: min(420px, 100%);
        padding: 12px 14px;
        border: 1px solid #b8c1b0;
        border-radius: 10px;
        font: inherit;
      }
    </style>
  </head>
  <body>
    <main>
      <h1>Hello from Servo</h1>
      <p>Real Servo content rendered inside Flutter on Linux.</p>
      <p>Select this text once input and pointer forwarding land.</p>
      <input value="Servo form control placeholder" />
    </main>
  </body>
</html>
"#;

    #[derive(Clone)]
    enum SessionContent {
        Url(Url),
        Html(String),
    }

    #[derive(Default)]
    struct ProxyOverrides {
        http_proxy_uri: Option<String>,
        https_proxy_uri: Option<String>,
        no_proxy: Option<String>,
    }

    #[derive(Clone)]
    struct SessionWaker {
        pending: Arc<AtomicBool>,
        #[cfg(target_os = "linux")]
        signal: Arc<crate::wake_signal::WakeSignal>,
    }

    impl EventLoopWaker for SessionWaker {
        fn clone_box(&self) -> Box<dyn EventLoopWaker> {
            Box::new(self.clone())
        }

        fn wake(&self) {
            self.pending.store(true, Ordering::Relaxed);
            #[cfg(target_os = "linux")]
            self.signal.notify();
        }
    }

    struct SessionDelegate {
        document_ready: Cell<bool>,
        frame_ready: Cell<bool>,
        load_status: Cell<LoadStatus>,
        animating: Cell<bool>,
        frame_epoch: Cell<u64>,
        crashed: Cell<bool>,
    }

    impl Default for SessionDelegate {
        fn default() -> Self {
            Self {
                document_ready: Cell::new(false),
                frame_ready: Cell::new(false),
                load_status: Cell::new(LoadStatus::Started),
                animating: Cell::new(false),
                frame_epoch: Cell::new(0),
                crashed: Cell::new(false),
            }
        }
    }

    impl SessionDelegate {
        fn begin_navigation(&self) {
            self.document_ready.set(false);
            self.frame_ready.set(false);
            self.load_status.set(LoadStatus::Started);
        }

        fn mark_frame_dirty(&self) {
            self.frame_ready.set(false);
        }

        fn is_scene_ready(&self) -> bool {
            self.document_ready.get() && self.frame_ready.get()
        }

        fn has_frame(&self) -> bool {
            self.frame_ready.get()
        }
    }

    impl WebViewDelegate for SessionDelegate {
        fn notify_new_frame_ready(&self, _webview: WebView) {
            if self.crashed.get() {
                return;
            }
            self.frame_ready.set(true);
            self.frame_epoch.set(self.frame_epoch.get().wrapping_add(1));
        }

        fn notify_load_status_changed(&self, _webview: WebView, status: LoadStatus) {
            if self.crashed.get() {
                return;
            }
            eprintln!("flutter_servo: rust delegate load status {status:?}");
            if matches!(status, LoadStatus::HeadParsed | LoadStatus::Complete) {
                self.document_ready.set(true);
            }
            self.load_status.set(status);
        }

        fn notify_animating_changed(&self, _webview: WebView, animating: bool) {
            self.animating.set(animating && !self.crashed.get());
        }

        fn notify_crashed(&self, _webview: WebView, reason: String, backtrace: Option<String>) {
            eprintln!("flutter_servo: Servo page crashed: {reason}");
            if let Some(backtrace) = backtrace {
                eprintln!("{backtrace}");
            }
            self.crashed.set(true);
            self.animating.set(false);
            self.frame_ready.set(false);
        }
    }

    pub(super) struct ServoRenderSession {
        rendering_context: Option<Rc<SoftwareRenderingContext>>,
        servo: Option<Servo>,
        delegate: Rc<SessionDelegate>,
        webview: Option<WebView>,
        content: SessionContent,
        pending_navigation: bool,
        size: PhysicalSize<u32>,
        rendered_frame_epoch: u64,
        wake_pending: Arc<AtomicBool>,
        #[cfg(target_os = "linux")]
        wake_signal: Arc<crate::wake_signal::WakeSignal>,
    }

    impl ServoRenderSession {
        fn new(proxy_overrides: ProxyOverrides) -> Result<Self, String> {
            eprintln!("flutter_servo: rust session new start");
            let size = PhysicalSize::new(800, 600);
            eprintln!("flutter_servo: rust session creating software rendering context");
            let rendering_context = Rc::new(
                SoftwareRenderingContext::new(size)
                    .map_err(|error| format!("software rendering init failed: {error:?}"))?,
            );
            eprintln!("flutter_servo: rust session making rendering context current");
            rendering_context
                .make_current()
                .map_err(|error| format!("software rendering activation failed: {error:?}"))?;

            let mut preferences = Preferences::default();
            if let Some(http_proxy_uri) = proxy_overrides.http_proxy_uri {
                preferences.network_http_proxy_uri = http_proxy_uri;
            }
            if let Some(https_proxy_uri) = proxy_overrides.https_proxy_uri {
                preferences.network_https_proxy_uri = https_proxy_uri;
            }
            if let Some(no_proxy) = proxy_overrides.no_proxy {
                preferences.network_http_no_proxy = no_proxy;
            }

            eprintln!("flutter_servo: rust session building Servo");
            let wake_pending = Arc::new(AtomicBool::new(true));
            #[cfg(target_os = "linux")]
            let wake_signal = Arc::new(
                crate::wake_signal::WakeSignal::new()
                    .map_err(|error| format!("wake channel init failed: {error}"))?,
            );
            let servo = ServoBuilder::default()
                .preferences(preferences)
                .event_loop_waker(Box::new(SessionWaker {
                    pending: wake_pending.clone(),
                    #[cfg(target_os = "linux")]
                    signal: wake_signal.clone(),
                }))
                .build();

            eprintln!("flutter_servo: rust session creating WebView");
            let delegate = Rc::new(SessionDelegate::default());
            delegate.begin_navigation();
            let webview = WebViewBuilder::new(&servo, rendering_context.clone())
                .delegate(delegate.clone())
                .url(data_url_for_html(DEFAULT_HTML)?)
                .build();
            eprintln!("flutter_servo: rust session created WebView");

            Ok(Self {
                rendering_context: Some(rendering_context),
                servo: Some(servo),
                delegate,
                webview: Some(webview),
                content: SessionContent::Html(DEFAULT_HTML.to_owned()),
                pending_navigation: false,
                size,
                rendered_frame_epoch: 0,
                wake_pending,
                #[cfg(target_os = "linux")]
                wake_signal,
            })
        }

        fn set_url(&mut self, url: &str) -> bool {
            let Ok(url) = Url::parse(url) else {
                return false;
            };
            self.content = SessionContent::Url(url);
            self.pending_navigation = true;
            true
        }

        fn set_html(&mut self, html: &str) -> bool {
            self.content = SessionContent::Html(html.to_owned());
            self.pending_navigation = true;
            true
        }

        fn go_back(&mut self) -> bool {
            let Some(webview) = self.webview.as_ref() else {
                return false;
            };
            if !webview.can_go_back() {
                return false;
            }
            self.delegate.begin_navigation();
            webview.go_back(1);
            true
        }

        fn go_forward(&mut self) -> bool {
            let Some(webview) = self.webview.as_ref() else {
                return false;
            };
            if !webview.can_go_forward() {
                return false;
            }
            self.delegate.begin_navigation();
            webview.go_forward(1);
            true
        }

        fn reload(&mut self) -> bool {
            if self.delegate.crashed.get() {
                self.pending_navigation = true;
                return true;
            }
            let Some(webview) = self.webview.as_ref() else {
                return false;
            };
            self.delegate.begin_navigation();
            webview.reload();
            true
        }

        fn navigation_state(&self) -> Option<(String, bool, bool)> {
            self.webview.as_ref().map(|webview| {
                (
                    webview
                        .url()
                        .map_or_else(String::new, |url| url.to_string()),
                    webview.can_go_back(),
                    webview.can_go_forward(),
                )
            })
        }

        fn is_animating(&self) -> bool {
            self.delegate.animating.get()
        }

        fn load_progress(&self) -> u8 {
            if self.delegate.crashed.get() {
                3
            } else if self.delegate.load_status.get() == LoadStatus::Complete {
                2
            } else if self.delegate.frame_ready.get() {
                1
            } else {
                0
            }
        }

        fn poll(&self) -> bool {
            if self.delegate.crashed.get() {
                return false;
            }
            let has_pending_frame = self.delegate.frame_epoch.get() != self.rendered_frame_epoch;
            let was_woken = self.wake_pending.swap(false, Ordering::Relaxed);
            if !self.delegate.animating.get() && !has_pending_frame && !was_woken {
                return false;
            }
            // Event dispatch can invoke the paint delegate before render_rgba.
            if self
                .rendering_context
                .as_ref()
                .is_none_or(|context| context.make_current().is_err())
            {
                return false;
            }
            if let Some(servo) = self.servo.as_ref() {
                servo.spin_event_loop();
            }
            self.delegate.animating.get()
                || self.delegate.frame_epoch.get() != self.rendered_frame_epoch
        }

        fn send_mouse_move(&self, x: i32, y: i32) -> bool {
            self.webview
                .as_ref()
                .map(|webview| {
                    webview.notify_input_event(InputEvent::MouseMove(MouseMoveEvent::new(
                        DevicePoint::new(x as f32, y as f32).into(),
                    )));
                    if let Some(servo) = self.servo.as_ref() {
                        servo.spin_event_loop();
                    }
                    true
                })
                .unwrap_or(false)
        }

        fn send_mouse_button(
            &self,
            x: i32,
            y: i32,
            button: MouseButton,
            action: MouseButtonAction,
        ) -> bool {
            let point = DevicePoint::new(x as f32, y as f32).into();
            self.webview
                .as_ref()
                .map(|webview| {
                    webview.notify_input_event(InputEvent::MouseMove(MouseMoveEvent::new(point)));
                    webview.notify_input_event(InputEvent::MouseButton(MouseButtonEvent::new(
                        action, button, point,
                    )));
                    true
                })
                .unwrap_or(false)
        }

        fn send_mouse_leave_viewport(&self) -> bool {
            self.webview
                .as_ref()
                .map(|webview| {
                    webview.notify_input_event(InputEvent::MouseLeftViewport(
                        MouseLeftViewportEvent::default(),
                    ));
                    true
                })
                .unwrap_or(false)
        }

        fn send_mouse_wheel(&self, x: i32, y: i32, delta_x: i32, delta_y: i32) -> bool {
            self.webview
                .as_ref()
                .map(|webview| {
                    webview.notify_input_event(InputEvent::Wheel(WheelEvent::new(
                        WheelDelta {
                            x: delta_x as f64,
                            y: delta_y as f64,
                            z: 0.0,
                            mode: WheelMode::DeltaPixel,
                        },
                        DevicePoint::new(x as f32, y as f32).into(),
                    )));
                    true
                })
                .unwrap_or(false)
        }

        fn send_keyboard_event(
            &self,
            key_label: &str,
            character: &str,
            key_state: KeyState,
        ) -> bool {
            let key = key_from_flutter_key(key_label, character);
            self.webview
                .as_ref()
                .map(|webview| {
                    webview.notify_input_event(InputEvent::Keyboard(
                        servo::KeyboardEvent::from_state_and_key(key_state, key),
                    ));
                    true
                })
                .unwrap_or(false)
        }

        fn focus_webview(&self) {
            if let Some(webview) = self.webview.as_ref() {
                webview.focus();
            }
        }

        fn blur_webview(&self) {
            if let Some(webview) = self.webview.as_ref() {
                webview.blur();
            }
        }

        fn render_image(&mut self, width: u32, height: u32) -> Option<RgbaImage> {
            let width = width.max(1);
            let height = height.max(1);

            if !self.prepare_for_render(width, height) {
                eprintln!("flutter_servo: rust render prepare failed");
                return None;
            }

            if let Some(servo) = self.servo.as_ref() {
                servo.spin_event_loop();
            } else {
                eprintln!("flutter_servo: rust render missing Servo event loop");
                return None;
            }

            if let Some(webview) = self.webview.as_ref() {
                webview.paint();
            } else {
                eprintln!("flutter_servo: rust render missing webview");
                return None;
            }

            let source_rectangle = DeviceIntRect::from_origin_and_size(
                DeviceIntPoint::zero(),
                DeviceIntSize::new(width as i32, height as i32),
            );
            let Some(rendering_context) = self.rendering_context.as_ref() else {
                eprintln!("flutter_servo: rust render missing rendering context");
                return None;
            };
            let Some(image) = rendering_context.read_to_image(source_rectangle) else {
                eprintln!("flutter_servo: rust render framebuffer read failed");
                return None;
            };
            let gl = rendering_context.gleam_gl_api();
            loop {
                let error = gl.get_error();
                if error == 0 {
                    break;
                }
                eprintln!(
                    "flutter_servo: rust render cleared GL error after framebuffer read: {error}"
                );
            }

            if image.width() != width || image.height() != height {
                return None;
            }
            self.rendered_frame_epoch = self.delegate.frame_epoch.get();
            Some(image)
        }

        fn render_rgba(
            &mut self,
            width: u32,
            height: u32,
            out_rgba: *mut u8,
            out_len: usize,
        ) -> bool {
            let width = width.max(1);
            let height = height.max(1);
            let expected_len = width as usize * height as usize * BYTES_PER_PIXEL;
            if out_rgba.is_null() || out_len < expected_len {
                eprintln!("flutter_servo: rust render rejected buffer");
                return false;
            }
            let Some(image) = self.render_image(width, height) else {
                return false;
            };
            copy_image_into_buffer(&image, width, height, unsafe {
                slice::from_raw_parts_mut(out_rgba, expected_len)
            })
        }

        fn prepare_for_render(&mut self, width: u32, height: u32) -> bool {
            let Some(rendering_context) = self.rendering_context.as_ref() else {
                eprintln!("flutter_servo: rust render missing rendering context");
                return false;
            };

            if rendering_context.make_current().is_err() {
                eprintln!("flutter_servo: rust render failed to make context current");
                return false;
            }

            let requested_size = PhysicalSize::new(width, height);
            if self.size != requested_size {
                eprintln!("flutter_servo: rust render resizing webview to {width}x{height}");
                if let Some(webview) = self.webview.as_ref() {
                    webview.resize(requested_size);
                } else {
                    eprintln!("flutter_servo: rust render missing webview for resize");
                    return false;
                }
                self.delegate.mark_frame_dirty();
                self.size = requested_size;
            }

            if self.pending_navigation {
                let Ok(url) = self.current_url() else {
                    eprintln!("flutter_servo: rust render failed to resolve content URL");
                    return false;
                };
                eprintln!("flutter_servo: rust render loading pending content");
                if self.delegate.crashed.get() {
                    let Some(servo) = self.servo.as_ref() else {
                        return false;
                    };
                    // Keep the engine/context, but isolate callbacks from the failed WebView.
                    let delegate = Rc::new(SessionDelegate::default());
                    let webview = WebViewBuilder::new(servo, rendering_context.clone())
                        .delegate(delegate.clone())
                        .url(url)
                        .build();
                    webview.resize(self.size);
                    self.webview = Some(webview);
                    self.delegate = delegate;
                    self.rendered_frame_epoch = 0;
                } else if let Some(webview) = self.webview.as_ref() {
                    self.delegate.begin_navigation();
                    webview.load(url);
                } else {
                    eprintln!("flutter_servo: rust render missing webview for navigation");
                    return false;
                }
                self.pending_navigation = false;
            }

            if self.delegate.crashed.get() {
                return false;
            }

            if !self.delegate.is_scene_ready() {
                eprintln!("flutter_servo: rust render waiting for scene readiness");
                if !self.spin_until(Duration::from_millis(250), || {
                    self.delegate.is_scene_ready()
                }) {
                    if self.delegate.has_frame() {
                        eprintln!(
                            "flutter_servo: rust render using available frame before document readiness"
                        );
                    } else {
                        eprintln!("flutter_servo: rust render frame not ready yet");
                        return false;
                    }
                }
            }

            true
        }

        fn current_url(&self) -> Result<Url, String> {
            match &self.content {
                SessionContent::Url(url) => Ok(url.clone()),
                SessionContent::Html(html) => data_url_for_html(html),
            }
        }

        fn spin_until(&self, timeout: Duration, done: impl Fn() -> bool) -> bool {
            let start = Instant::now();
            while !done() {
                if self.delegate.crashed.get() {
                    return false;
                }
                if start.elapsed() >= timeout {
                    eprintln!("flutter_servo: rust spin_until timed out after {timeout:?}");
                    return false;
                }
                if let Some(servo) = self.servo.as_ref() {
                    servo.spin_event_loop();
                } else {
                    return false;
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            true
        }
    }

    impl Drop for ServoRenderSession {
        fn drop(&mut self) {
            eprintln!("flutter_servo: rust session shutdown start");
            if let Some(webview) = self.webview.take() {
                drop(webview);
                if let Some(servo) = self.servo.as_ref() {
                    let deadline = Instant::now() + Duration::from_millis(100);
                    while Instant::now() < deadline {
                        servo.spin_event_loop();
                        std::thread::sleep(Duration::from_millis(1));
                    }
                }
            }
            let _ = self.servo.take();
            let _ = self.rendering_context.take();
            eprintln!("flutter_servo: rust session shutdown complete");
        }
    }

    fn copy_image_into_buffer(
        image: &RgbaImage,
        width: u32,
        height: u32,
        out_rgba: &mut [u8],
    ) -> bool {
        if image.width() != width || image.height() != height {
            return false;
        }

        let raw = image.as_raw();
        if raw.len() != out_rgba.len() {
            return false;
        }

        out_rgba.copy_from_slice(raw);
        true
    }

    fn data_url_for_html(html: &str) -> Result<Url, String> {
        Url::parse(&format!(
            "data:text/html;charset=utf-8,{}",
            utf8_percent_encode(html, NON_ALPHANUMERIC)
        ))
        .map_err(|error| format!("html data URL parse failed: {error}"))
    }

    fn key_from_flutter_key(key_label: &str, character: &str) -> Key {
        if !character.is_empty() {
            return Key::Character(character.into());
        }

        let normalized = key_label
            .trim()
            .to_ascii_lowercase()
            .replace([' ', '_', '-'], "");

        match normalized.as_str() {
            "backspace" => Key::Named(NamedKey::Backspace),
            "tab" => Key::Named(NamedKey::Tab),
            "enter" | "numpadenter" => Key::Named(NamedKey::Enter),
            "escape" | "esc" => Key::Named(NamedKey::Escape),
            "space" | "spacebar" => Key::Character(" ".into()),
            "arrowleft" | "leftarrow" => Key::Named(NamedKey::ArrowLeft),
            "arrowright" | "rightarrow" => Key::Named(NamedKey::ArrowRight),
            "arrowup" | "uparrow" => Key::Named(NamedKey::ArrowUp),
            "arrowdown" | "downarrow" => Key::Named(NamedKey::ArrowDown),
            "delete" | "del" => Key::Named(NamedKey::Delete),
            "insert" | "ins" => Key::Named(NamedKey::Insert),
            "home" => Key::Named(NamedKey::Home),
            "end" => Key::Named(NamedKey::End),
            "pageup" => Key::Named(NamedKey::PageUp),
            "pagedown" => Key::Named(NamedKey::PageDown),
            "shift" | "shiftleft" | "shiftright" => Key::Named(NamedKey::Shift),
            "control" | "ctrl" | "controlleft" | "controlright" => Key::Named(NamedKey::Control),
            "alt" | "altleft" | "altright" => Key::Named(NamedKey::Alt),
            "meta" | "super" | "metaleft" | "metaright" => Key::Named(NamedKey::Meta),
            _ if key_label.chars().count() == 1 => Key::Character(key_label.into()),
            _ => Key::Named(NamedKey::Unidentified),
        }
    }

    #[no_mangle]
    fn optional_c_string(ptr: *const c_char) -> Option<String> {
        c_string(ptr).map(|value| value.to_owned())
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_new(
        http_proxy_uri: *const c_char,
        https_proxy_uri: *const c_char,
        no_proxy: *const c_char,
    ) -> *mut c_void {
        eprintln!("flutter_servo: ffi session_new invoked");
        let proxy_overrides = ProxyOverrides {
            http_proxy_uri: optional_c_string(http_proxy_uri),
            https_proxy_uri: optional_c_string(https_proxy_uri),
            no_proxy: optional_c_string(no_proxy),
        };
        match std::panic::catch_unwind(|| ServoRenderSession::new(proxy_overrides)) {
            Ok(Ok(session)) => {
                eprintln!("flutter_servo: ffi session_new success");
                Box::into_raw(Box::new(session)).cast()
            }
            Ok(Err(error)) => {
                eprintln!("flutter_servo: ffi session_new error: {error}");
                null_mut()
            }
            Err(_) => {
                eprintln!("flutter_servo: ffi session_new panicked");
                null_mut()
            }
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_free(session: *mut c_void) {
        if !session.is_null() {
            drop(Box::from_raw(session.cast::<ServoRenderSession>()));
        }
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
            eprintln!("flutter_servo: rust render panicked");
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
        catch_unwind(AssertUnwindSafe(|| session.render_image(width, height)))
            .ok()
            .flatten()
            .map_or(null_mut(), |image| {
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
}

#[cfg(not(feature = "servo-engine"))]
mod imp {
    use std::ptr::null_mut;

    use super::{c_char, c_string, c_void, slice, ALPHA, BYTES_PER_PIXEL};

    enum DemoContent {
        Url(String),
        Html(String),
    }

    struct DemoSession {
        content: DemoContent,
    }

    #[no_mangle]
    pub extern "C" fn flutter_servo_session_new(
        _http_proxy_uri: *const c_char,
        _https_proxy_uri: *const c_char,
        _no_proxy: *const c_char,
    ) -> *mut c_void {
        Box::into_raw(Box::new(DemoSession {
            content: DemoContent::Url(
                "data:text/html;charset=utf-8,<html><body><h1>Hello from Servo</h1><p>Rendered inside Flutter.</p></body></html>"
                    .to_owned(),
            ),
        })) as *mut c_void
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_free(session: *mut c_void) {
        if !session.is_null() {
            drop(Box::from_raw(session.cast::<DemoSession>()));
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_set_url(
        session: *mut c_void,
        url: *const c_char,
    ) -> bool {
        let Some(session) = session.cast::<DemoSession>().as_mut() else {
            return false;
        };
        let Some(url) = c_string(url) else {
            return false;
        };

        session.content = DemoContent::Url(url.to_owned());
        true
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_set_html(
        session: *mut c_void,
        html: *const c_char,
    ) -> bool {
        let Some(session) = session.cast::<DemoSession>().as_mut() else {
            return false;
        };
        let Some(html) = c_string(html) else {
            return false;
        };

        session.content = DemoContent::Html(html.to_owned());
        true
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_go_back(_session: *mut c_void) -> bool {
        false
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_go_forward(_session: *mut c_void) -> bool {
        false
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_reload(session: *mut c_void) -> bool {
        !session.is_null()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_is_animating(_session: *const c_void) -> bool {
        false
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_load_progress(session: *const c_void) -> u8 {
        if session.is_null() {
            0
        } else {
            2
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_poll(_session: *const c_void) -> bool {
        false
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_get_navigation_state(
        session: *const c_void,
        url_out: *mut c_char,
        url_out_len: usize,
        can_go_back_out: *mut bool,
        can_go_forward_out: *mut bool,
    ) -> bool {
        let Some(session) = session.cast::<DemoSession>().as_ref() else {
            return false;
        };
        if url_out.is_null()
            || url_out_len == 0
            || can_go_back_out.is_null()
            || can_go_forward_out.is_null()
        {
            return false;
        }
        let url = match &session.content {
            DemoContent::Url(value) => value.as_str(),
            DemoContent::Html(_) => "data:text/html",
        };
        let bytes = url.as_bytes();
        let copy_len = bytes.len().min(url_out_len - 1);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), url_out.cast::<u8>(), copy_len);
        *url_out.add(copy_len) = 0;
        *can_go_back_out = false;
        *can_go_forward_out = false;
        true
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_notify_mouse_move(
        session: *mut c_void,
        _x: i32,
        _y: i32,
    ) -> bool {
        !session.is_null()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_notify_mouse_button(
        session: *mut c_void,
        _x: i32,
        _y: i32,
        _button: u8,
        _is_down: bool,
    ) -> bool {
        !session.is_null()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_notify_mouse_leave_viewport(
        session: *mut c_void,
    ) -> bool {
        !session.is_null()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_notify_mouse_wheel(
        session: *mut c_void,
        _x: i32,
        _y: i32,
        _delta_x: i32,
        _delta_y: i32,
    ) -> bool {
        !session.is_null()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_notify_key_event(
        session: *mut c_void,
        _key_label: *const c_char,
        _character: *const c_char,
        _is_down: bool,
    ) -> bool {
        !session.is_null()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_focus_webview(session: *mut c_void) -> bool {
        !session.is_null()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_blur_webview(session: *mut c_void) -> bool {
        !session.is_null()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_render_rgba(
        session: *const c_void,
        width: u32,
        height: u32,
        out_rgba: *mut u8,
        out_len: usize,
    ) -> bool {
        let Some(session) = session.cast::<DemoSession>().as_ref() else {
            return false;
        };

        let width = width.max(1);
        let height = height.max(1);
        let expected_len = width as usize * height as usize * BYTES_PER_PIXEL;
        if out_rgba.is_null() || out_len < expected_len {
            return false;
        }

        let buffer = slice::from_raw_parts_mut(out_rgba, expected_len);
        paint_demo_frame(session, width, height, buffer);
        true
    }

    struct ExportedFrame(Vec<u8>);

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_render_frame(
        session: *mut c_void,
        width: u32,
        height: u32,
        data_out: *mut *const u8,
        len_out: *mut usize,
    ) -> *mut c_void {
        let Some(session) = session.cast::<DemoSession>().as_ref() else {
            return null_mut();
        };
        if data_out.is_null() || len_out.is_null() {
            return null_mut();
        }
        let width = width.max(1);
        let height = height.max(1);
        let mut buffer = vec![0; width as usize * height as usize * BYTES_PER_PIXEL];
        paint_demo_frame(session, width, height, &mut buffer);
        let frame = Box::new(ExportedFrame(buffer));
        *data_out = frame.0.as_ptr();
        *len_out = frame.0.len();
        Box::into_raw(frame).cast()
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_frame_free(frame: *mut c_void) {
        if !frame.is_null() {
            drop(Box::from_raw(frame.cast::<ExportedFrame>()));
        }
    }

    fn paint_demo_frame(session: &DemoSession, width: u32, height: u32, buffer: &mut [u8]) {
        let (content_kind, content) = match &session.content {
            DemoContent::Url(value) => ("URL", value.as_str()),
            DemoContent::Html(value) => ("HTML", value.as_str()),
        };

        let hash = hash_seed(content);
        let accent_r = 48 + (hash & 0x3f) as u8;
        let accent_g = 110 + ((hash >> 8) & 0x4f) as u8;
        let accent_b = 120 + ((hash >> 16) & 0x5f) as u8;

        for y in 0..height {
            for x in 0..width {
                let yf = if height > 1 {
                    y as f32 / (height - 1) as f32
                } else {
                    0.0
                };
                let xf = if width > 1 {
                    x as f32 / (width - 1) as f32
                } else {
                    0.0
                };

                let r = (250.0 - yf * 18.0 - xf * 4.0).round() as u8;
                let g = (247.0 - yf * 10.0 + xf * 4.0).round() as u8;
                let b = (241.0 - yf * 6.0 + xf * 8.0).round() as u8;
                write_pixel(buffer, width, x, y, r, g, b);
            }
        }

        let toolbar_height = 56u32.max(height / 9);
        fill_rect(
            buffer,
            width,
            height,
            0,
            0,
            width,
            toolbar_height,
            [230, 233, 229],
        );

        let badge_x = 16;
        let badge_y = toolbar_height / 4;
        let badge_width = 64u32.min(width.saturating_sub(32));
        let badge_color = if matches!(session.content, DemoContent::Html(_)) {
            [44, 116, 92]
        } else {
            [32, 97, 163]
        };
        fill_rect(
            buffer,
            width,
            height,
            badge_x,
            badge_y,
            badge_width,
            24,
            badge_color,
        );

        let address_x = 24u32.max(width / 8);
        let address_y = toolbar_height / 4;
        let address_width = width.saturating_sub(address_x * 2).min(width * 3 / 4);
        let address_height = 28u32.max(toolbar_height / 2);
        fill_rect(
            buffer,
            width,
            height,
            address_x,
            address_y,
            address_width,
            address_height,
            [246, 247, 245],
        );
        let address_hash = hash_seed(content_kind);
        draw_token_stripes(
            buffer,
            width,
            height,
            content,
            address_x + 12,
            address_y + 8,
            address_width.saturating_sub(24),
            12,
            [
                90 + (address_hash & 0x3f) as u8,
                120 + ((address_hash >> 8) & 0x2f) as u8,
                110 + ((address_hash >> 16) & 0x2f) as u8,
            ],
        );

        let hero_margin = 36u32.max(width / 18);
        let hero_y = toolbar_height + 28u32.max(height / 24);
        let hero_height = 84u32.max(height / 5);
        fill_rect(
            buffer,
            width,
            height,
            hero_margin,
            hero_y,
            width.saturating_sub(hero_margin * 2),
            hero_height,
            [accent_r, accent_g, accent_b],
        );

        let subhero_y = hero_y + 18;
        let subhero_width = width.saturating_sub(hero_margin * 2 + 40);
        draw_token_stripes(
            buffer,
            width,
            height,
            content,
            hero_margin + 20,
            subhero_y,
            subhero_width,
            14,
            [245, 247, 244],
        );

        let card_y = hero_y + hero_height + 24u32.max(height / 32);
        let card_width = width.saturating_sub(hero_margin * 2);
        let card_height = 160u32.max(height.saturating_sub(card_y + 32u32.max(height / 28)));
        fill_rect(
            buffer,
            width,
            height,
            hero_margin,
            card_y,
            card_width,
            card_height,
            [255, 255, 255],
        );

        let article_text = match &session.content {
            DemoContent::Url(url) => url.as_str(),
            DemoContent::Html(html) => extract_html_text(html),
        };
        let line_x = hero_margin + 18u32.max(width / 48);
        let mut line_y = card_y + 22u32.max(height / 40);
        let max_line_width = card_width.saturating_sub(36u32.max(width / 20));
        for line_width in derive_line_widths(article_text, max_line_width, 8) {
            fill_rect(
                buffer,
                width,
                height,
                line_x,
                line_y,
                line_width,
                12,
                [213, 218, 214],
            );
            line_y = line_y.saturating_add(26);
            if line_y.saturating_add(12) >= card_y.saturating_add(card_height) {
                break;
            }
        }
    }

    fn draw_token_stripes(
        buffer: &mut [u8],
        frame_width: u32,
        frame_height: u32,
        content: &str,
        x: u32,
        y: u32,
        available_width: u32,
        stripe_height: u32,
        rgb: [u8; 3],
    ) {
        if available_width == 0 {
            return;
        }

        let widths = derive_line_widths(content, available_width, 5);
        let mut cursor_x = x;
        for width in widths {
            fill_rect(
                buffer,
                frame_width,
                frame_height,
                cursor_x,
                y,
                width.min(available_width.saturating_sub(cursor_x.saturating_sub(x))),
                stripe_height,
                rgb,
            );
            cursor_x = cursor_x.saturating_add(width + 8);
            if cursor_x >= x.saturating_add(available_width) {
                break;
            }
        }
    }

    fn derive_line_widths(content: &str, max_width: u32, max_lines: usize) -> Vec<u32> {
        let mut result = Vec::with_capacity(max_lines);
        let safe_width = max_width.max(72);
        for (index, token) in tokenize(content).into_iter().take(max_lines).enumerate() {
            let base = 48 + ((token.len() as u32 * 9) % safe_width.max(49));
            let width = base.min(safe_width);
            result.push(if index % 3 == 2 {
                width.saturating_sub(24).max(64)
            } else {
                width.max(64)
            });
        }
        if result.is_empty() {
            result.push((safe_width * 3 / 4).max(96));
        }
        result
    }

    fn tokenize(content: &str) -> Vec<String> {
        content
            .split(|char: char| !char.is_alphanumeric())
            .filter(|part| !part.is_empty())
            .map(ToOwned::to_owned)
            .collect()
    }

    fn extract_html_text(html: &str) -> &str {
        if let Some(body_start) = html.find("<body") {
            return &html[body_start..];
        }
        html
    }

    fn hash_seed(seed: &str) -> u32 {
        let mut value = 2166136261u32;
        for byte in seed.bytes() {
            value ^= byte as u32;
            value = value.wrapping_mul(16777619);
        }
        value
    }

    fn write_pixel(buffer: &mut [u8], width: u32, x: u32, y: u32, r: u8, g: u8, b: u8) {
        let index = ((y * width + x) as usize) * BYTES_PER_PIXEL;
        buffer[index] = r;
        buffer[index + 1] = g;
        buffer[index + 2] = b;
        buffer[index + 3] = ALPHA;
    }

    fn fill_rect(
        buffer: &mut [u8],
        frame_width: u32,
        frame_height: u32,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        rgb: [u8; 3],
    ) {
        let max_x = (x + width).min(frame_width);
        let max_y = (y + height).min(frame_height);
        for yy in y..max_y {
            for xx in x..max_x {
                write_pixel(buffer, frame_width, xx, yy, rgb[0], rgb[1], rgb[2]);
            }
        }
    }
}

fn c_string<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }

    unsafe { CStr::from_ptr(ptr).to_str().ok() }
}
