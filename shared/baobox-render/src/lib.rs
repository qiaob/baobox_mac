//! Baobox 共享渲染层：把标注光栅化进 RGBA 缓冲。
//!
//! 为什么放共享层：标注是**截图的一部分**，同一张图在三个平台上必须长得一样。
//! 交给各平台的绘图 API（Core Graphics / GDI / Xlib）去画，线宽、端点、
//! 抗锯齿的差异会让同一份标注在不同系统上明显不同。这里自己光栅化，输出逐像素一致。
//!
//! **文字是唯一的例外**：字形栅格化需要字体引擎，自带一份字体既臃肿又覆盖不了中文。
//! 文字由平台层用系统 API 画上去（GDI `TextOutW` / X11 `image_text8` / Core Text），
//! 位置与颜色仍由这里给出。

#![forbid(unsafe_code)]

use baobox_core::annotation::{Color, Shape, Tool};

/// 一块可写的 RGBA8 画布。
pub struct Canvas<'a> {
    /// 宽（像素）
    pub width: usize,
    /// 高（像素）
    pub height: usize,
    /// RGBA8 像素，长度必须是 `width * height * 4`
    pub pixels: &'a mut [u8],
}

impl<'a> Canvas<'a> {
    /// 包一块缓冲；尺寸不符返回 `None`。
    pub fn new(width: usize, height: usize, pixels: &'a mut [u8]) -> Option<Self> {
        if width == 0 || height == 0 || pixels.len() != width * height * 4 {
            return None;
        }
        Some(Self {
            width,
            height,
            pixels,
        })
    }

    /// 读一个像素（越界返回 `None`）。
    pub fn get(&self, x: i64, y: i64) -> Option<[u8; 4]> {
        let index = self.index(x, y)?;
        Some([
            self.pixels[index],
            self.pixels[index + 1],
            self.pixels[index + 2],
            self.pixels[index + 3],
        ])
    }

    /// 按 alpha 混合一个像素。越界静默忽略 —— 标注拖出画布边缘是常见操作，
    /// 不该因此报错或 panic。
    pub fn blend(&mut self, x: i64, y: i64, color: Color) {
        let Some(index) = self.index(x, y) else {
            return;
        };
        if color.a == 0 {
            return;
        }
        if color.a == 255 {
            self.pixels[index] = color.r;
            self.pixels[index + 1] = color.g;
            self.pixels[index + 2] = color.b;
            self.pixels[index + 3] = 255;
            return;
        }
        let alpha = color.a as u32;
        let inverse = 255 - alpha;
        for (offset, channel) in [color.r, color.g, color.b].into_iter().enumerate() {
            let existing = self.pixels[index + offset] as u32;
            self.pixels[index + offset] =
                ((channel as u32 * alpha + existing * inverse) / 255) as u8;
        }
        self.pixels[index + 3] = 255;
    }

    fn index(&self, x: i64, y: i64) -> Option<usize> {
        if x < 0 || y < 0 || x as usize >= self.width || y as usize >= self.height {
            return None;
        }
        Some((y as usize * self.width + x as usize) * 4)
    }
}

/// 把一份标注文档画到画布上，按绘制顺序。
///
/// `Tool::Text` 在这里**只画不出来** —— 返回值里给出需要平台层补画的文字，
/// 位置与颜色已经算好。
pub fn render(shapes: &[Shape], canvas: &mut Canvas<'_>) -> Vec<TextDraw> {
    let mut texts = Vec::new();
    for shape in shapes {
        match shape.tool {
            Tool::Rect => stroke_rect(canvas, shape),
            Tool::Ellipse => stroke_ellipse(canvas, shape),
            Tool::Arrow => stroke_arrow(canvas, shape),
            Tool::Pen => stroke_polyline(canvas, shape, shape.color),
            Tool::Highlighter => {
                // 荧光笔：半透明 + 更粗，压在下面的内容仍看得见
                let mut color = shape.color;
                color.a = 90;
                stroke_polyline(canvas, shape, color);
            }
            Tool::Mosaic => mosaic(canvas, shape),
            Tool::Text => {
                if let (Some(text), Some(&(x, y))) = (shape.text.as_ref(), shape.points.first()) {
                    texts.push(TextDraw {
                        x,
                        y,
                        size: shape.width.max(8.0),
                        color: shape.color,
                        text: text.clone(),
                    });
                }
            }
            // 橡皮不产生图形，它的效果是从文档里删掉某一笔
            Tool::Eraser => {}
        }
    }
    texts
}

/// 需要平台层用系统字体补画的一段文字。
#[derive(Debug, Clone, PartialEq)]
pub struct TextDraw {
    /// 左上角 x
    pub x: f64,
    /// 左上角 y
    pub y: f64,
    /// 字号
    pub size: f64,
    /// 颜色
    pub color: Color,
    /// 内容
    pub text: String,
}

/// 画一条带宽度的线段。
///
/// 用 Bresenham 走主轴，再在每个点上盖一个方形笔刷。比画圆形笔刷快得多，
/// 而在截图标注这个尺度上（线宽 2–8 像素）肉眼分辨不出差别。
pub fn line(canvas: &mut Canvas<'_>, from: (f64, f64), to: (f64, f64), width: f64, color: Color) {
    let half = (width / 2.0).max(0.5);
    let (mut x0, mut y0) = (from.0.round() as i64, from.1.round() as i64);
    let (x1, y1) = (to.0.round() as i64, to.1.round() as i64);

    let dx = (x1 - x0).abs();
    let dy = -(y1 - y0).abs();
    let sx = if x0 < x1 { 1 } else { -1 };
    let sy = if y0 < y1 { 1 } else { -1 };
    let mut error = dx + dy;

    loop {
        brush(canvas, x0, y0, half, color);
        if x0 == x1 && y0 == y1 {
            break;
        }
        let doubled = 2 * error;
        if doubled >= dy {
            error += dy;
            x0 += sx;
        }
        if doubled <= dx {
            error += dx;
            y0 += sy;
        }
    }
}

fn brush(canvas: &mut Canvas<'_>, cx: i64, cy: i64, half: f64, color: Color) {
    let radius = half.ceil() as i64;
    for y in -radius..=radius {
        for x in -radius..=radius {
            canvas.blend(cx + x, cy + y, color);
        }
    }
}

fn stroke_polyline(canvas: &mut Canvas<'_>, shape: &Shape, color: Color) {
    if shape.points.len() == 1 {
        // 单点也要留下痕迹：用户点一下就抬手是常见操作
        brush(
            canvas,
            shape.points[0].0.round() as i64,
            shape.points[0].1.round() as i64,
            (shape.width / 2.0).max(0.5),
            color,
        );
        return;
    }
    for pair in shape.points.windows(2) {
        line(canvas, pair[0], pair[1], shape.width, color);
    }
}

fn stroke_rect(canvas: &mut Canvas<'_>, shape: &Shape) {
    let bounds = shape.bounds();
    let (left, top) = (bounds.x, bounds.y);
    let (right, bottom) = (bounds.right(), bounds.bottom());
    let corners = [
        ((left, top), (right, top)),
        ((right, top), (right, bottom)),
        ((right, bottom), (left, bottom)),
        ((left, bottom), (left, top)),
    ];
    for (from, to) in corners {
        line(canvas, from, to, shape.width, shape.color);
    }
}

/// 画空心椭圆。中点椭圆算法的对称四象限版本。
fn stroke_ellipse(canvas: &mut Canvas<'_>, shape: &Shape) {
    let bounds = shape.bounds();
    let rx = bounds.w / 2.0;
    let ry = bounds.h / 2.0;
    if rx < 0.5 || ry < 0.5 {
        return;
    }
    let cx = bounds.x + rx;
    let cy = bounds.y + ry;
    let half = (shape.width / 2.0).max(0.5);

    // 按周长估采样点数，保证长轴很长时也不出现断点
    let steps = ((rx + ry) * 4.0).max(32.0) as usize;
    for step in 0..steps {
        let angle = step as f64 / steps as f64 * std::f64::consts::TAU;
        let x = cx + rx * angle.cos();
        let y = cy + ry * angle.sin();
        brush(canvas, x.round() as i64, y.round() as i64, half, shape.color);
    }
}

/// 画箭头：主干 + 两条回勾。
fn stroke_arrow(canvas: &mut Canvas<'_>, shape: &Shape) {
    let (Some(&from), Some(&to)) = (shape.points.first(), shape.points.last()) else {
        return;
    };
    line(canvas, from, to, shape.width, shape.color);

    let dx = to.0 - from.0;
    let dy = to.1 - from.1;
    let length = dx.hypot(dy);
    if length < 1.0 {
        return;
    }
    // 箭头大小随线宽走，细线配小箭头才好看
    let head = (shape.width * 4.0).clamp(8.0, length * 0.5);
    let angle = dy.atan2(dx);
    for offset in [0.5, -0.5] {
        let wing = angle + std::f64::consts::PI + offset;
        let tip = (to.0 + head * wing.cos(), to.1 + head * wing.sin());
        line(canvas, to, tip, shape.width, shape.color);
    }
}

/// 马赛克：把包围盒切成方块，每块取平均色填回去。
///
/// 块大小随线宽走 —— 用户调粗就是想遮得更狠。
pub fn mosaic(canvas: &mut Canvas<'_>, shape: &Shape) {
    let bounds = shape.bounds();
    let block = (shape.width * 2.0).clamp(4.0, 64.0) as i64;
    let left = bounds.x.floor() as i64;
    let top = bounds.y.floor() as i64;
    let right = bounds.right().ceil() as i64;
    let bottom = bounds.bottom().ceil() as i64;

    let mut y = top;
    while y < bottom {
        let mut x = left;
        while x < right {
            average_block(canvas, x, y, block, right, bottom);
            x += block;
        }
        y += block;
    }
}

fn average_block(
    canvas: &mut Canvas<'_>,
    x0: i64,
    y0: i64,
    block: i64,
    right: i64,
    bottom: i64,
) {
    let (mut r, mut g, mut b, mut count) = (0u64, 0u64, 0u64, 0u64);
    for y in y0..(y0 + block).min(bottom) {
        for x in x0..(x0 + block).min(right) {
            if let Some(pixel) = canvas.get(x, y) {
                r += pixel[0] as u64;
                g += pixel[1] as u64;
                b += pixel[2] as u64;
                count += 1;
            }
        }
    }
    if count == 0 {
        return;
    }
    let color = Color {
        r: (r / count) as u8,
        g: (g / count) as u8,
        b: (b / count) as u8,
        a: 255,
    };
    for y in y0..(y0 + block).min(bottom) {
        for x in x0..(x0 + block).min(right) {
            canvas.blend(x, y, color);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use baobox_core::annotation::{Color, Shape, Tool};

    fn blank(width: usize, height: usize) -> Vec<u8> {
        vec![255u8; width * height * 4] // 全白
    }

    fn shape(tool: Tool, points: Vec<(f64, f64)>, width: f64) -> Shape {
        Shape {
            tool,
            points,
            color: Color::rgb(255, 0, 0),
            width,
            text: None,
        }
    }

    #[test]
    fn canvas_rejects_mismatched_buffers() {
        let mut pixels = vec![0u8; 10];
        assert!(Canvas::new(4, 4, &mut pixels).is_none());
        let mut ok = blank(2, 2);
        assert!(Canvas::new(2, 2, &mut ok).is_some());
    }

    #[test]
    fn out_of_bounds_drawing_is_ignored_not_panicking() {
        let mut pixels = blank(8, 8);
        let mut canvas = Canvas::new(8, 8, &mut pixels).unwrap();
        // 整条线都在画布外
        line(&mut canvas, (-50.0, -50.0), (-10.0, -10.0), 4.0, Color::rgb(0, 0, 0));
        // 一半在外
        line(&mut canvas, (-5.0, 4.0), (20.0, 4.0), 2.0, Color::rgb(0, 0, 0));
        assert_eq!(canvas.get(0, 4).unwrap()[0], 0, "画布内的部分仍应画上");
    }

    #[test]
    fn opaque_color_replaces_and_translucent_blends() {
        let mut pixels = blank(2, 1);
        let mut canvas = Canvas::new(2, 1, &mut pixels).unwrap();
        canvas.blend(0, 0, Color::rgb(0, 0, 0));
        assert_eq!(canvas.get(0, 0).unwrap(), [0, 0, 0, 255]);
        // 半透明黑压在白底上应得到中灰
        canvas.blend(
            1,
            0,
            Color {
                r: 0,
                g: 0,
                b: 0,
                a: 128,
            },
        );
        let blended = canvas.get(1, 0).unwrap();
        assert!(blended[0] > 100 && blended[0] < 160, "应是中灰，实得 {blended:?}");
    }

    #[test]
    fn rectangle_is_hollow() {
        let mut pixels = blank(40, 40);
        let mut canvas = Canvas::new(40, 40, &mut pixels).unwrap();
        render(&[shape(Tool::Rect, vec![(5.0, 5.0), (35.0, 35.0)], 2.0)], &mut canvas);
        // 边框被画上
        assert_eq!(canvas.get(5, 20).unwrap()[1], 0, "左边框应有色");
        assert_eq!(canvas.get(35, 20).unwrap()[1], 0, "右边框应有色");
        // 中间仍是白的
        assert_eq!(canvas.get(20, 20).unwrap(), [255, 255, 255, 255]);
    }

    #[test]
    fn ellipse_touches_the_four_extremes_and_leaves_the_middle() {
        let mut pixels = blank(60, 60);
        let mut canvas = Canvas::new(60, 60, &mut pixels).unwrap();
        render(
            &[shape(Tool::Ellipse, vec![(10.0, 10.0), (50.0, 50.0)], 2.0)],
            &mut canvas,
        );
        // 上下左右四个极点附近应有笔迹
        assert_eq!(canvas.get(30, 10).unwrap()[1], 0, "顶点");
        assert_eq!(canvas.get(30, 50).unwrap()[1], 0, "底点");
        assert_eq!(canvas.get(10, 30).unwrap()[1], 0, "左点");
        assert_eq!(canvas.get(50, 30).unwrap()[1], 0, "右点");
        assert_eq!(canvas.get(30, 30).unwrap(), [255, 255, 255, 255], "中心应为空");
    }

    #[test]
    fn arrow_draws_a_head_near_the_tip() {
        let mut pixels = blank(60, 30);
        let mut canvas = Canvas::new(60, 30, &mut pixels).unwrap();
        render(&[shape(Tool::Arrow, vec![(5.0, 15.0), (50.0, 15.0)], 2.0)], &mut canvas);
        // 主干
        assert_eq!(canvas.get(25, 15).unwrap()[1], 0);
        // 箭头回勾应当在末端上下方留下痕迹
        let above = (5..14).any(|y| canvas.get(44, y).map(|p| p[1] == 0).unwrap_or(false));
        let below = (16..25).any(|y| canvas.get(44, y).map(|p| p[1] == 0).unwrap_or(false));
        assert!(above && below, "箭头两条回勾都应画上");
    }

    #[test]
    fn highlighter_is_translucent_but_pen_is_not() {
        let mut pixels = blank(20, 20);
        let mut canvas = Canvas::new(20, 20, &mut pixels).unwrap();
        render(
            &[shape(Tool::Highlighter, vec![(2.0, 10.0), (18.0, 10.0)], 4.0)],
            &mut canvas,
        );
        let marked = canvas.get(10, 10).unwrap();
        // 半透明红压白底 → 绿蓝通道被拉低但不到 0
        assert!(marked[1] > 0 && marked[1] < 255, "荧光笔应半透明，实得 {marked:?}");

        let mut pen_pixels = blank(20, 20);
        let mut pen_canvas = Canvas::new(20, 20, &mut pen_pixels).unwrap();
        render(
            &[shape(Tool::Pen, vec![(2.0, 10.0), (18.0, 10.0)], 4.0)],
            &mut pen_canvas,
        );
        assert_eq!(pen_canvas.get(10, 10).unwrap()[1], 0, "画笔应不透明");
    }

    #[test]
    fn mosaic_flattens_detail_into_blocks() {
        // 造一块黑白相间的棋盘，打上马赛克后应变成均匀灰
        let mut pixels = Vec::new();
        for y in 0..16 {
            for x in 0..16 {
                let value = if (x + y) % 2 == 0 { 0 } else { 255 };
                pixels.extend_from_slice(&[value, value, value, 255]);
            }
        }
        let mut canvas = Canvas::new(16, 16, &mut pixels).unwrap();
        render(&[shape(Tool::Mosaic, vec![(0.0, 0.0), (16.0, 16.0)], 4.0)], &mut canvas);

        let a = canvas.get(1, 1).unwrap();
        let b = canvas.get(2, 2).unwrap();
        assert_eq!(a, b, "同一块内的像素应当一致");
        assert!(a[0] > 100 && a[0] < 160, "黑白各半应平均成中灰，实得 {a:?}");
    }

    #[test]
    fn single_point_pen_still_leaves_a_mark() {
        let mut pixels = blank(10, 10);
        let mut canvas = Canvas::new(10, 10, &mut pixels).unwrap();
        render(&[shape(Tool::Pen, vec![(5.0, 5.0)], 4.0)], &mut canvas);
        assert_eq!(canvas.get(5, 5).unwrap()[1], 0, "点一下就抬手也要留痕");
    }

    #[test]
    fn text_is_handed_back_for_the_platform_to_draw() {
        let mut pixels = blank(10, 10);
        let mut canvas = Canvas::new(10, 10, &mut pixels).unwrap();
        let mut text_shape = shape(Tool::Text, vec![(3.0, 4.0)], 14.0);
        text_shape.text = Some("你好".to_string());
        let texts = render(&[text_shape], &mut canvas);
        assert_eq!(texts.len(), 1);
        assert_eq!(texts[0].text, "你好");
        assert_eq!((texts[0].x, texts[0].y), (3.0, 4.0));
        // 画布本身没被文字改动
        assert_eq!(canvas.get(3, 4).unwrap(), [255, 255, 255, 255]);
    }

    #[test]
    fn eraser_draws_nothing() {
        let mut pixels = blank(10, 10);
        let mut canvas = Canvas::new(10, 10, &mut pixels).unwrap();
        render(&[shape(Tool::Eraser, vec![(0.0, 0.0), (9.0, 9.0)], 4.0)], &mut canvas);
        assert_eq!(canvas.get(5, 5).unwrap(), [255, 255, 255, 255]);
    }
}
