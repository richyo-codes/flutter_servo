pub(crate) struct FrameSize {
    pub width: u32,
    pub height: u32,
    pub rgba_len: usize,
}

impl FrameSize {
    pub fn new(width: u32, height: u32) -> Option<Self> {
        let width = width.max(1);
        let height = height.max(1);
        i32::try_from(width).ok()?;
        i32::try_from(height).ok()?;
        let rgba_len = (width as usize)
            .checked_mul(height as usize)?
            .checked_mul(4)?;
        (rgba_len <= isize::MAX as usize).then_some(Self {
            width,
            height,
            rgba_len,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::FrameSize;

    #[test]
    fn validates_signed_dimensions_and_slice_size() {
        assert!(FrameSize::new(u32::MAX, 1).is_none());
        assert!(FrameSize::new(i32::MAX as u32, i32::MAX as u32).is_none());
        assert_eq!(FrameSize::new(1920, 1080).unwrap().rgba_len, 8_294_400);
        let empty = FrameSize::new(0, 0).unwrap();
        assert_eq!((empty.width, empty.height, empty.rgba_len), (1, 1, 4));
    }
}
