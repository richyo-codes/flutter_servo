#![cfg(feature = "servo-engine")]

use std::rc::Rc;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use dpi::PhysicalSize;
use servo::{
    EventLoopWaker, Preferences, RenderingContext, Servo, ServoBuilder, SoftwareRenderingContext,
    WebView, WebViewBuilder, WebViewDelegate,
};
use url::Url;

#[derive(Clone)]
struct ServoSpikeWaker(Arc<AtomicBool>);

impl EventLoopWaker for ServoSpikeWaker {
    fn clone_box(&self) -> Box<dyn EventLoopWaker> {
        Box::new(self.clone())
    }

    fn wake(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

#[derive(Default)]
struct ServoSpikeDelegate;

impl WebViewDelegate for ServoSpikeDelegate {}

#[allow(dead_code)]
pub(crate) struct ServoCompileSpike {
    pub(crate) servo: Servo,
    pub(crate) rendering_context: Rc<SoftwareRenderingContext>,
    pub(crate) webview: WebView,
}

#[allow(dead_code)]
impl ServoCompileSpike {
    pub(crate) fn new_data_url() -> Result<Self, String> {
        let rendering_context = Rc::new(
            SoftwareRenderingContext::new(PhysicalSize::new(800, 600))
                .map_err(|error| format!("software rendering context init failed: {error:?}"))?,
        );
        rendering_context
            .make_current()
            .map_err(|error| format!("software rendering context activation failed: {error:?}"))?;

        let mut preferences = Preferences::default();
        preferences.network_http_proxy_uri = String::new();
        preferences.network_https_proxy_uri = String::new();

        let servo = ServoBuilder::default()
            .preferences(preferences)
            .event_loop_waker(Box::new(ServoSpikeWaker(Arc::new(AtomicBool::new(false)))))
            .build();

        let webview = WebViewBuilder::new(&servo, rendering_context.clone())
            .delegate(Rc::new(ServoSpikeDelegate))
            .url(
                Url::parse(
                    "data:text/html,<!DOCTYPE html><html><body><h1>Hello from Servo</h1><p>In-process compile spike.</p></body></html>",
                )
                .map_err(|error| format!("data URL parse failed: {error}"))?,
            )
            .build();

        Ok(Self {
            servo,
            rendering_context,
            webview,
        })
    }

    pub(crate) fn spin_once(&self) {
        self.servo.spin_event_loop();
    }

    pub(crate) fn paint_once(&self) {
        self.webview.paint();
    }
}
