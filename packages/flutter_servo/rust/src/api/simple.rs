#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello from Rust, {name}.")
}

#[flutter_rust_bridge::frb(sync)]
pub fn mvp_initial_url() -> String {
    "data:text/html;charset=utf-8,<html><body><h1>Hello from Servo</h1><p>Rendered inside Flutter.</p></body></html>".to_owned()
}

#[flutter_rust_bridge::frb(sync)]
pub fn mvp_initial_html() -> String {
    r#"<html>
  <body>
    <h1>Hello from Servo</h1>
    <p>Rendered inside Flutter.</p>
  </body>
</html>"#
        .to_owned()
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
