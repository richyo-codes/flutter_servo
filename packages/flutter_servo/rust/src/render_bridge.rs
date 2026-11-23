use std::ffi::{c_void, CStr};
use std::os::raw::c_char;
use std::slice;

const BYTES_PER_PIXEL: usize = 4;

#[cfg(feature = "servo-engine")]
mod imp {
    use std::cell::{Cell, RefCell};
    use std::panic::{catch_unwind, AssertUnwindSafe};
    use std::ptr::null_mut;
    use std::rc::Rc;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, OnceLock,
    };
    use std::time::Instant;

    use dpi::PhysicalSize;
    use euclid::Scale;
    use gleam::gl;
    use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
    use servo::{DeviceIntPoint, DeviceIntRect, DeviceIntSize};
    use servo::{
        DevicePoint, EventLoopWaker, InputEvent, KeyState, LoadStatus, MouseButton,
        MouseButtonAction, MouseButtonEvent, MouseLeftViewportEvent, MouseMoveEvent, Preferences,
        RenderingContext, RgbaImage, Servo, ServoBuilder, SoftwareRenderingContext, WebView,
        WebViewBuilder, WebViewDelegate, WheelDelta, WheelEvent, WheelMode,
    };
    use url::Url;

    use crate::accessibility::PageAccessibility;
    use super::{c_char, c_string, c_void, slice, BYTES_PER_PIXEL};

    fn log_elapsed_ms() -> u128 {
        static START: OnceLock<Instant> = OnceLock::new();
        START.get_or_init(Instant::now).elapsed().as_millis()
    }

    macro_rules! render_log {
        ($($arg:tt)*) => {
            eprintln!("[+{} ms] {}", log_elapsed_ms(), format_args!($($arg)*))
        };
    }

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
        callback: Arc<crate::wake_callback::WakeCallback>,
        #[cfg(target_os = "linux")]
        signal: Arc<crate::wake_signal::WakeSignal>,
    }

    impl EventLoopWaker for SessionWaker {
        fn clone_box(&self) -> Box<dyn EventLoopWaker> {
            Box::new(self.clone())
        }

        fn wake(&self) {
            self.pending.store(true, Ordering::Relaxed);
            self.callback.notify();
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
        controls: RefCell<crate::embedder_controls::Controls>,
        accessibility: RefCell<PageAccessibility>,
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
                controls: RefCell::new(crate::embedder_controls::Controls::default()),
                accessibility: RefCell::default(),
            }
        }
    }

    impl SessionDelegate {
        fn begin_navigation(&self) {
            self.controls.borrow_mut().reset();
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
        fn notify_accessibility_tree_update(&self, _webview: WebView, update: accesskit::TreeUpdate) {
            self.accessibility.borrow_mut().update(update);
        }

        fn show_embedder_control(&self, _webview: WebView, control: servo::EmbedderControl) {
            if !self.crashed.get() {
                self.controls.borrow_mut().show(control);
            }
        }

        fn hide_embedder_control(&self, _webview: WebView, id: servo::EmbedderControlId) {
            self.controls.borrow_mut().hide(id);
        }

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
            render_log!("flutter_servo: rust delegate load status {status:?}");
            if matches!(status, LoadStatus::HeadParsed | LoadStatus::Complete) {
                self.document_ready.set(true);
            }
            self.load_status.set(status);
        }

        fn notify_animating_changed(&self, _webview: WebView, animating: bool) {
            self.animating.set(animating && !self.crashed.get());
        }

        fn notify_crashed(&self, _webview: WebView, reason: String, backtrace: Option<String>) {
            render_log!("flutter_servo: Servo page crashed: {reason}");
            if let Some(backtrace) = backtrace {
                eprintln!("{backtrace}");
            }
            self.crashed.set(true);
            self.accessibility.borrow_mut().set_root(None);
            self.controls.borrow_mut().reset();
            self.animating.set(false);
            self.frame_ready.set(false);
        }
    }

    pub(super) struct ServoRenderSession {
        rendering_context: Option<Rc<dyn RenderingContext>>,
        servo: Option<Servo>,
        delegate: Rc<SessionDelegate>,
        webview: Option<WebView>,
        content: SessionContent,
        pending_navigation: bool,
        size: PhysicalSize<u32>,
        display_scale: f32,
        page_zoom: f32,
        accessibility_enabled: Cell<bool>,
        rendered_frame_epoch: u64,
        wake_pending: Arc<AtomicBool>,
        wake_callback: Arc<crate::wake_callback::WakeCallback>,
        keyboard: RefCell<crate::keyboard_input::KeyboardState>,
        #[cfg(target_os = "linux")]
        wake_signal: Arc<crate::wake_signal::WakeSignal>,
    }

    impl ServoRenderSession {
        fn new(proxy_overrides: ProxyOverrides) -> Result<Self, String> {
            render_log!("flutter_servo: rust session new start");
            let size = PhysicalSize::new(800, 600);
            render_log!("flutter_servo: rust session creating rendering context");
            let prefer_hardware = match std::env::var("FLUTTER_SERVO_GPU_TEXTURES").as_deref() {
                Ok("1") => true,
                Ok("0") => false,
                _ => cfg!(target_os = "windows"),
            };
            let rendering_context: Rc<dyn RenderingContext> =
                if prefer_hardware {
                    match crate::gpu_context::GpuContext::new(size) {
                        Ok(context) => Rc::new(context),
                        Err(error) => {
                            render_log!("flutter_servo: hardware context unavailable: {error:?}");
                            Rc::new(
                                SoftwareRenderingContext::new(size)
                                    .map_err(|error| format!("rendering init failed: {error:?}"))?,
                            )
                        }
                    }
                } else {
                    Rc::new(
                        SoftwareRenderingContext::new(size)
                            .map_err(|error| format!("rendering init failed: {error:?}"))?,
                    )
                };
            render_log!("flutter_servo: rust session making rendering context current");
            rendering_context
                .make_current()
                .map_err(|error| format!("software rendering activation failed: {error:?}"))?;
            let gl = rendering_context.gleam_gl_api();
            render_log!(
                "flutter_servo: Servo graphics vendor={:?} renderer={:?} version={:?}",
                gl.get_string(gl::VENDOR),
                gl.get_string(gl::RENDERER),
                gl.get_string(gl::VERSION),
            );

            let mut preferences = Preferences::default();
            preferences.accessibility_enabled = true;
            if let Some(http_proxy_uri) = proxy_overrides.http_proxy_uri {
                preferences.network_http_proxy_uri = http_proxy_uri;
            }
            if let Some(https_proxy_uri) = proxy_overrides.https_proxy_uri {
                preferences.network_https_proxy_uri = https_proxy_uri;
            }
            if let Some(no_proxy) = proxy_overrides.no_proxy {
                preferences.network_http_no_proxy = no_proxy;
            }

            render_log!("flutter_servo: rust session building Servo");
            let wake_pending = Arc::new(AtomicBool::new(true));
            let wake_callback = Arc::new(crate::wake_callback::WakeCallback::default());
            #[cfg(target_os = "linux")]
            let wake_signal = Arc::new(
                crate::wake_signal::WakeSignal::new()
                    .map_err(|error| format!("wake channel init failed: {error}"))?,
            );
            let servo = ServoBuilder::default()
                .preferences(preferences)
                .event_loop_waker(Box::new(SessionWaker {
                    pending: wake_pending.clone(),
                    callback: wake_callback.clone(),
                    #[cfg(target_os = "linux")]
                    signal: wake_signal.clone(),
                }))
                .build();

            let delegate = Rc::new(SessionDelegate::default());

            Ok(Self {
                rendering_context: Some(rendering_context),
                servo: Some(servo),
                delegate,
                // Build the first WebView with the requested content. Starting a demo
                // navigation here races the first host navigation before Servo spins.
                webview: None,
                content: SessionContent::Url(Url::parse("about:blank").unwrap()),
                pending_navigation: true,
                size,
                display_scale: 1.0,
                page_zoom: 1.0,
                accessibility_enabled: Cell::new(false),
                rendered_frame_epoch: 0,
                wake_pending,
                wake_callback,
                keyboard: RefCell::new(crate::keyboard_input::KeyboardState::default()),
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
            } else if matches!(
                self.delegate.load_status.get(),
                LoadStatus::Complete | LoadStatus::Stopped
            ) {
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
            let event = self
                .keyboard
                .borrow_mut()
                .event(key_label, character, key_state);
            self.webview
                .as_ref()
                .map(|webview| {
                    use crate::keyboard_input::EditingShortcut;
                    let input = match crate::keyboard_input::editing_shortcut(&event) {
                        Some(EditingShortcut::Copy) => InputEvent::EditingAction(
                            servo::ClipboardAction::Copy,
                        ),
                        Some(EditingShortcut::Cut) => InputEvent::EditingAction(
                            servo::ClipboardAction::Cut,
                        ),
                        Some(EditingShortcut::Paste) => InputEvent::EditingAction(
                            servo::ClipboardAction::Paste,
                        ),
                        None => InputEvent::Keyboard(servo::KeyboardEvent::new(event)),
                    };
                    webview.notify_input_event(input);
                    true
                })
                .unwrap_or(false)
        }

        fn focus_webview(&self) {
            if let Some(webview) = self.webview.as_ref() {
                webview.set_focused(true);
            }
        }

        fn blur_webview(&self) {
            self.keyboard.borrow_mut().clear();
            if let Some(webview) = self.webview.as_ref() {
                webview.set_focused(false);
            }
        }

        fn paint(&mut self, width: u32, height: u32) -> bool {
            let width = width.max(1);
            let height = height.max(1);

            if !self.prepare_for_render(width, height) {
                render_log!("flutter_servo: rust render prepare failed");
                return false;
            }

            if let Some(servo) = self.servo.as_ref() {
                servo.spin_event_loop();
            } else {
                render_log!("flutter_servo: rust render missing Servo event loop");
                return false;
            }

            if let Some(webview) = self.webview.as_ref() {
                webview.paint();
            } else {
                render_log!("flutter_servo: rust render missing webview");
                return false;
            }

            if let Some(context) = self.rendering_context.as_ref() {
                context.prepare_for_rendering();
            }
            self.rendered_frame_epoch = self.delegate.frame_epoch.get();
            true
        }

        fn render_image(&mut self, width: u32, height: u32) -> Option<RgbaImage> {
            let width = width.max(1);
            let height = height.max(1);
            if !self.paint(width, height) {
                return None;
            }

            let source_rectangle = DeviceIntRect::from_origin_and_size(
                DeviceIntPoint::zero(),
                DeviceIntSize::new(width as i32, height as i32),
            );
            let Some(rendering_context) = self.rendering_context.as_ref() else {
                render_log!("flutter_servo: rust render missing rendering context");
                return None;
            };
            let Some(image) = rendering_context.read_to_image(source_rectangle) else {
                render_log!("flutter_servo: rust render framebuffer read failed");
                return None;
            };
            let gl = rendering_context.gleam_gl_api();
            loop {
                let error = gl.get_error();
                if error == 0 {
                    break;
                }
                render_log!(
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
                render_log!("flutter_servo: rust render rejected buffer");
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
                render_log!("flutter_servo: rust render missing rendering context");
                return false;
            };

            if rendering_context.make_current().is_err() {
                render_log!("flutter_servo: rust render failed to make context current");
                return false;
            }

            let requested_size = PhysicalSize::new(width, height);
            if self.size != requested_size {
                render_log!("flutter_servo: rust render resizing webview to {width}x{height}");
                if let Some(webview) = self.webview.as_ref() {
                    webview.resize(requested_size);
                } else {
                    rendering_context.resize(requested_size);
                }
                self.delegate.mark_frame_dirty();
                self.size = requested_size;
            }

            if self.pending_navigation {
                let Ok(url) = self.current_url() else {
                    render_log!("flutter_servo: rust render failed to resolve content URL");
                    return false;
                };
                render_log!("flutter_servo: rust render loading pending content");
                if self.webview.is_none() || self.delegate.crashed.get() {
                    let Some(servo) = self.servo.as_ref() else {
                        return false;
                    };
                    // Keep the engine/context, but isolate callbacks from the failed WebView.
                    let delegate = Rc::new(SessionDelegate::default());
                    let webview = WebViewBuilder::new(servo, rendering_context.clone())
                        .delegate(delegate.clone())
                        .hidpi_scale_factor(Scale::new(self.display_scale))
                        .url(url)
                        .build();
                    webview.resize(self.size);
                    webview.set_page_zoom(self.page_zoom);
                    let accessibility_root =
                        webview.set_accessibility_active(self.accessibility_enabled.get());
                    delegate.accessibility.borrow_mut().set_root(accessibility_root);
                    self.webview = Some(webview);
                    self.delegate = delegate;
                    self.rendered_frame_epoch = 0;
                } else if let Some(webview) = self.webview.as_ref() {
                    self.delegate.begin_navigation();
                    webview.load(url);
                } else {
                    render_log!("flutter_servo: rust render missing webview for navigation");
                    return false;
                }
                self.pending_navigation = false;
            }

            if let Some(servo) = self.servo.as_ref() {
                servo.spin_event_loop();
            }
            if self.delegate.crashed.get() {
                return false;
            }

            if !self.delegate.is_scene_ready() {
                // The wake-driven GTK pump will retry when Servo publishes a frame.
                // Never wait for a scene on the UI thread.
                return self.delegate.has_frame();
            }

            true
        }

        fn current_url(&self) -> Result<Url, String> {
            match &self.content {
                SessionContent::Url(url) => Ok(url.clone()),
                SessionContent::Html(html) => data_url_for_html(html),
            }
        }
    }

    impl Drop for ServoRenderSession {
        fn drop(&mut self) {
            self.wake_callback.set(None, null_mut());
            render_log!("flutter_servo: rust session shutdown start");
            self.delegate.controls.borrow_mut().reset();
            if let Some(context) = self.rendering_context.as_ref() {
                // Flutter may have changed the current GL context since the last paint.
                let _ = context.make_current();
            }
            let _ = self.webview.take();
            // Servo's destructor drains its shutdown protocol; an arbitrary delay adds
            // latency without proving its threads have stopped.
            let _ = self.servo.take();
            let _ = self.rendering_context.take();
            render_log!("flutter_servo: rust session shutdown complete");
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
            drop(Box::from_raw(session.cast::<ServoRenderSession>()));
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
        catch_unwind(AssertUnwindSafe(|| session.paint(width, height))).unwrap_or(false)
    }

    #[no_mangle]
    pub unsafe extern "C" fn flutter_servo_session_take_control_event(
        session: *mut c_void,
    ) -> *mut c_char {
        let Some(session) = session.cast::<ServoRenderSession>().as_ref() else {
            return null_mut();
        };
        let control_event = session.delegate.controls.borrow_mut().take_event();
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

fn c_string<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }

    unsafe { CStr::from_ptr(ptr).to_str().ok() }
}
