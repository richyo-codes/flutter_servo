/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// Based on Servo's Surfman rendering contexts, using the hardware adapter for
// an offscreen surface. Servo's public offscreen constructor requires a window.
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

use dpi::PhysicalSize;
use euclid::default::Size2D;
use gleam::gl::{self, Gl};
use servo::{DeviceIntRect, RenderingContext, RgbaImage};
use surfman::chains::{PreserveBuffer, SwapChain};
use surfman::{
    Connection, Context, ContextAttributeFlags, ContextAttributes, Device, Error, GLApi, GLVersion,
    Surface, SurfaceAccess, SurfaceTexture, SurfaceType,
};

struct ContextOwner {
    device: Device,
    context: Context,
}

impl Drop for ContextOwner {
    fn drop(&mut self) {
        if let Ok(Some(mut surface)) = self.device.unbind_surface_from_context(&mut self.context) {
            let _ = self.device.destroy_surface(&mut self.context, &mut surface);
        }
        let _ = self.device.destroy_context(&mut self.context);
    }
}

pub(crate) struct GpuContext {
    owner: RefCell<ContextOwner>,
    swap_chain: SwapChain<Device>,
    size: Cell<PhysicalSize<u32>>,
    gl: Rc<dyn Gl>,
    glow: Arc<glow::Context>,
}

impl GpuContext {
    pub fn new(size: PhysicalSize<u32>) -> Result<Self, Error> {
        // This surface is never attached to a native window. Select the
        // surfaceless EGL backend explicitly instead of opening a second
        // compositor connection (which can select llvmpipe under GTK).
        #[cfg(target_os = "linux")]
        let connection =
            Connection::Alternate(surfman::mesa_surfaceless::connection::Connection::new()?);
        #[cfg(not(target_os = "linux"))]
        let connection = Connection::new()?;
        let adapter = connection.create_adapter()?;
        let device = connection.create_device(&adapter)?;
        let api = connection.gl_api();
        let version = match api {
            GLApi::GLES => GLVersion::new(3, 0),
            GLApi::GL => GLVersion::new(3, 2),
        };
        let descriptor = device.create_context_descriptor(&ContextAttributes {
            flags: ContextAttributeFlags::ALPHA
                | ContextAttributeFlags::DEPTH
                | ContextAttributeFlags::STENCIL,
            version,
        })?;
        let context = device.create_context(&descriptor, None)?;
        let mut owner = ContextOwner { device, context };
        let surface = owner.device.create_surface(
            &owner.context,
            SurfaceAccess::GPUOnly,
            SurfaceType::Generic {
                size: Size2D::new(size.width as i32, size.height as i32),
            },
        )?;
        owner
            .device
            .bind_surface_to_context(&mut owner.context, surface)
            .map_err(|(error, mut surface)| {
                let _ = owner
                    .device
                    .destroy_surface(&mut owner.context, &mut surface);
                error
            })?;
        owner.device.make_context_current(&owner.context)?;
        let gl: Rc<dyn Gl> = unsafe {
            match api {
                GLApi::GL => {
                    gl::GlFns::load_with(|name| owner.device.get_proc_address(&owner.context, name))
                }
                GLApi::GLES => gl::GlesFns::load_with(|name| {
                    owner.device.get_proc_address(&owner.context, name)
                }),
            }
        };
        let glow = Arc::new(unsafe {
            glow::Context::from_loader_function(|name| {
                owner.device.get_proc_address(&owner.context, name)
            })
        });
        let swap_chain = SwapChain::create_attached(
            &mut owner.device,
            &mut owner.context,
            SurfaceAccess::GPUOnly,
        )?;
        eprintln!(
            "flutter_servo: hardware context renderer={}",
            gl.get_string(gl::RENDERER)
        );
        Ok(Self {
            owner: RefCell::new(owner),
            swap_chain,
            size: Cell::new(size),
            gl,
            glow,
        })
    }
}

impl RenderingContext for GpuContext {
    fn prepare_for_rendering(&self) {
        let owner = self.owner.borrow();
        let framebuffer = owner
            .device
            .context_surface_info(&owner.context)
            .ok()
            .flatten()
            .and_then(|info| info.framebuffer_object)
            .map_or(0, |framebuffer| framebuffer.0.get());
        self.gl.bind_framebuffer(gl::FRAMEBUFFER, framebuffer);
    }

    fn read_to_image(&self, rect: DeviceIntRect) -> Option<RgbaImage> {
        self.prepare_for_rendering();
        self.gl.bind_vertex_array(0);
        let mut pixels = self.gl.read_pixels(
            rect.min.x,
            rect.min.y,
            rect.width(),
            rect.height(),
            gl::RGBA,
            gl::UNSIGNED_BYTE,
        );
        let stride = rect.width() as usize * 4;
        for y in 0..rect.height() as usize / 2 {
            let opposite = rect.height() as usize - y - 1;
            for x in 0..stride {
                pixels.swap(y * stride + x, opposite * stride + x);
            }
        }
        RgbaImage::from_raw(rect.width() as u32, rect.height() as u32, pixels)
    }

    fn size(&self) -> PhysicalSize<u32> {
        self.size.get()
    }

    fn resize(&self, size: PhysicalSize<u32>) {
        if self.size.get() == size {
            return;
        }
        let mut owner = self.owner.borrow_mut();
        let ContextOwner { device, context } = &mut *owner;
        match self.swap_chain.resize(
            device,
            context,
            Size2D::new(size.width as i32, size.height as i32),
        ) {
            Ok(()) => self.size.set(size),
            Err(error) => eprintln!("flutter_servo: GPU resize failed: {error:?}"),
        }
    }

    fn present(&self) {
        let mut owner = self.owner.borrow_mut();
        let ContextOwner { device, context } = &mut *owner;
        let _ = self
            .swap_chain
            .swap_buffers(device, context, PreserveBuffer::No);
    }

    fn make_current(&self) -> Result<(), Error> {
        let owner = self.owner.borrow();
        owner.device.make_context_current(&owner.context)
    }
    fn gleam_gl_api(&self) -> Rc<dyn Gl> {
        self.gl.clone()
    }
    fn glow_gl_api(&self) -> Arc<glow::Context> {
        self.glow.clone()
    }
    fn connection(&self) -> Option<Connection> {
        Some(self.owner.borrow().device.connection())
    }

    fn create_texture(&self, surface: Surface) -> Option<(SurfaceTexture, u32, Size2D<i32>)> {
        let mut owner = self.owner.borrow_mut();
        let ContextOwner { device, context } = &mut *owner;
        let size = device.surface_info(&surface).size;
        let texture = match device.create_surface_texture(context, surface) {
            Ok(texture) => texture,
            Err((_, mut surface)) => {
                let _ = device.destroy_surface(context, &mut surface);
                return None;
            }
        };
        let id = device
            .surface_texture_object(&texture)
            .map_or(0, |texture| texture.0.get());
        Some((texture, id, size))
    }

    fn destroy_texture(&self, texture: SurfaceTexture) -> Option<Surface> {
        let mut owner = self.owner.borrow_mut();
        let ContextOwner { device, context } = &mut *owner;
        device
            .destroy_surface_texture(context, texture)
            .map_err(|(error, _)| error)
            .ok()
    }
}

impl Drop for GpuContext {
    fn drop(&mut self) {
        let ContextOwner { device, context } = self.owner.get_mut();
        let _ = device.make_context_current(context);
        let _ = self.swap_chain.destroy(device, context);
    }
}
