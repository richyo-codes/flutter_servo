use std::cell::{Cell, RefCell};
use std::ptr::null_mut;
use std::rc::Rc;
use std::slice;
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
    DevicePoint, EventLoopWaker, InputEvent, KeyState, LoadStatus, MouseButton, MouseButtonAction,
    MouseButtonEvent, MouseLeftViewportEvent, MouseMoveEvent, Preferences, RenderingContext,
    RgbaImage, Servo, ServoBuilder, SoftwareRenderingContext, WebView, WebViewBuilder,
    WebViewDelegate, WheelDelta, WheelEvent, WheelMode,
};
use url::Url;

use crate::accessibility::PageAccessibility;

fn log_elapsed_ms() -> u128 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis()
}

use crate::frame_size::FrameSize;

macro_rules! render_log {
    ($($arg:tt)*) => {
        eprintln!("[+{} ms] {}", log_elapsed_ms(), format_args!($($arg)*))
    };
}

mod ffi;

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
    cursor_update: Cell<Option<servo::Cursor>>,
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
            cursor_update: Cell::new(Some(servo::Cursor::Default)),
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
        self.cursor_update.set(Some(servo::Cursor::Default));
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
    fn notify_cursor_changed(&self, _webview: WebView, cursor: servo::Cursor) {
        if !self.crashed.get() {
            self.cursor_update.set(Some(cursor));
        }
    }

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
        self.cursor_update.set(Some(servo::Cursor::Default));
        self.accessibility.borrow_mut().set_root(None);
        self.controls.borrow_mut().reset();
        self.animating.set(false);
        self.frame_ready.set(false);
    }
}

struct ServoRenderSession {
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
        let rendering_context: Rc<dyn RenderingContext> = if prefer_hardware {
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

    fn send_keyboard_event(&self, key_label: &str, character: &str, key_state: KeyState) -> bool {
        let event = self
            .keyboard
            .borrow_mut()
            .event(key_label, character, key_state);
        self.webview
            .as_ref()
            .map(|webview| {
                use crate::keyboard_input::EditingShortcut;
                let input = match crate::keyboard_input::editing_shortcut(&event) {
                    Some(EditingShortcut::Copy) => {
                        InputEvent::EditingAction(servo::ClipboardAction::Copy)
                    }
                    Some(EditingShortcut::Cut) => {
                        InputEvent::EditingAction(servo::ClipboardAction::Cut)
                    }
                    Some(EditingShortcut::Paste) => {
                        InputEvent::EditingAction(servo::ClipboardAction::Paste)
                    }
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

    fn paint(&mut self, size: &FrameSize) -> bool {
        if !self.prepare_for_render(size.width, size.height) {
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

    fn render_image(&mut self, size: &FrameSize) -> Option<RgbaImage> {
        let (width, height) = (size.width, size.height);
        if !self.paint(size) {
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

    fn render_rgba(&mut self, width: u32, height: u32, out_rgba: *mut u8, out_len: usize) -> bool {
        let Some(size) = FrameSize::new(width, height) else {
            return false;
        };
        let expected_len = size.rgba_len;
        if out_rgba.is_null() || out_len < expected_len {
            render_log!("flutter_servo: rust render rejected buffer");
            return false;
        }
        let Some(image) = self.render_image(&size) else {
            return false;
        };
        copy_image_into_buffer(&image, size.width, size.height, unsafe {
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
                delegate
                    .accessibility
                    .borrow_mut()
                    .set_root(accessibility_root);
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

fn copy_image_into_buffer(image: &RgbaImage, width: u32, height: u32, out_rgba: &mut [u8]) -> bool {
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
