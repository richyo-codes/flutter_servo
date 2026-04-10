#[cfg(feature = "servo-engine")]
fn main() {
    use dpi::PhysicalSize;
    use servo::{RenderingContext, SoftwareRenderingContext};

    eprintln!("flutter_servo_probe: start");
    eprintln!("flutter_servo_probe: creating SoftwareRenderingContext");
    let context = SoftwareRenderingContext::new(PhysicalSize::new(800, 600))
        .expect("SoftwareRenderingContext::new should succeed");
    eprintln!("flutter_servo_probe: created SoftwareRenderingContext");
    context
        .make_current()
        .expect("SoftwareRenderingContext::make_current should succeed");
    eprintln!("flutter_servo_probe: made rendering context current");
}

#[cfg(not(feature = "servo-engine"))]
fn main() {
    eprintln!("Enable the `servo-engine` feature to run this probe.");
}
