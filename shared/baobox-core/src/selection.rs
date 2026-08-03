//! 截图选区状态机。
//!
//! 复刻 macOS 侧 `CaptureController` / `CaptureOverlayView` 的交互规格，但只保留状态迁移，
//! 不含任何绘制与事件循环 —— 平台层把鼠标键盘事件喂进来，拿走一个 [`Outcome`]。
//!
//! 规格（三平台必须一致）：
//!
//! - 悬停高亮鼠标下的窗口，单击即截该窗口
//! - 按下并移动超过阈值 → 转为区域选择（低于阈值仍算点击）
//! - 选区拉好后可拖八向手柄微调
//! - 方向键逐像素移动选区，按住 Shift 时 ×10
//! - Enter 截全屏，Esc 取消

use crate::geometry::{handle_at, resize, Handle, Rect};

/// 按下后移动多少才从「点击窗口」转为「拖拽选区」。与 macOS 侧一致。
pub const DRAG_THRESHOLD: f64 = 4.0;

/// 手柄命中半径。
pub const HANDLE_TOLERANCE: f64 = 8.0;

/// 方向键每次移动的像素数。
pub const NUDGE_STEP: f64 = 1.0;

/// 按住 Shift 时方向键的倍数。
pub const NUDGE_FAST_MULTIPLIER: f64 = 10.0;

/// 选区交互的当前阶段。
#[derive(Debug, Clone, PartialEq)]
pub enum Phase {
    /// 未按下，正在悬停（可能高亮着某个窗口）
    Hovering {
        /// 命中的窗口在窗口列表里的下标
        window: Option<usize>,
    },
    /// 已按下但还没超过阈值 —— 松开算点击
    Pressed {
        /// 按下点
        origin: (f64, f64),
        /// 按下时命中的窗口
        window: Option<usize>,
    },
    /// 正在拖拽出一个新选区
    Dragging {
        /// 起点
        origin: (f64, f64),
        /// 当前点
        current: (f64, f64),
    },
    /// 选区已成形，可微调
    Adjusting {
        /// 当前选区
        rect: Rect,
        /// 正在拖动的手柄（`None` = 没在拖）
        dragging: Option<Handle>,
        /// 手柄拖动的上一个位置
        last: (f64, f64),
    },
    /// 交互结束
    Done,
}

/// 交互的最终结果。
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// 截取某个窗口（列表下标）
    Window(usize),
    /// 截取一块区域
    Region(Rect),
    /// 截取整个屏幕
    FullScreen,
    /// 用户取消
    Cancelled,
}

/// 键盘事件。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    /// 方向键
    Left,
    /// 方向键
    Right,
    /// 方向键
    Up,
    /// 方向键
    Down,
    /// 回车
    Enter,
    /// Esc
    Escape,
}

/// 选区状态机。
#[derive(Debug, Clone)]
pub struct Selection {
    phase: Phase,
    /// 屏幕边界，选区不会被移出这个范围
    bounds: Rect,
    /// 可命中的窗口矩形（按 z 序从前到后）
    windows: Vec<Rect>,
    outcome: Option<Outcome>,
}

impl Selection {
    /// 新建一个处于悬停态的选区。
    pub fn new(bounds: Rect, windows: Vec<Rect>) -> Self {
        Self {
            phase: Phase::Hovering { window: None },
            bounds,
            windows,
            outcome: None,
        }
    }

    /// 当前阶段。
    pub fn phase(&self) -> &Phase {
        &self.phase
    }

    /// 交互结果；未结束时为 `None`。
    pub fn outcome(&self) -> Option<&Outcome> {
        self.outcome.as_ref()
    }

    /// 当前应当高亮 / 显示的矩形，供平台层绘制。
    pub fn current_rect(&self) -> Option<Rect> {
        match &self.phase {
            Phase::Hovering { window } | Phase::Pressed { window, .. } => {
                window.and_then(|i| self.windows.get(i)).copied()
            }
            Phase::Dragging { origin, current } => Some(Rect::from_points(
                origin.0, origin.1, current.0, current.1,
            )),
            Phase::Adjusting { rect, .. } => Some(*rect),
            Phase::Done => None,
        }
    }

    /// 命中最靠前的那个包含该点的窗口。
    fn window_at(&self, point: (f64, f64)) -> Option<usize> {
        self.windows
            .iter()
            .position(|w| w.contains(point.0, point.1))
    }

    /// 鼠标移动。
    pub fn mouse_moved(&mut self, point: (f64, f64)) {
        match &self.phase {
            Phase::Hovering { .. } => {
                self.phase = Phase::Hovering {
                    window: self.window_at(point),
                };
            }
            Phase::Pressed { origin, window } => {
                let moved = (point.0 - origin.0).hypot(point.1 - origin.1);
                if moved > DRAG_THRESHOLD {
                    self.phase = Phase::Dragging {
                        origin: *origin,
                        current: point,
                    };
                } else {
                    // 还没过阈值，保持 Pressed（松手仍算点击窗口）
                    self.phase = Phase::Pressed {
                        origin: *origin,
                        window: *window,
                    };
                }
            }
            Phase::Dragging { origin, .. } => {
                self.phase = Phase::Dragging {
                    origin: *origin,
                    current: point,
                };
            }
            Phase::Adjusting {
                rect,
                dragging: Some(handle),
                last,
            } => {
                let resized = resize(rect, *handle, point.0 - last.0, point.1 - last.1);
                self.phase = Phase::Adjusting {
                    rect: resized.clamped_to(&self.bounds),
                    dragging: Some(*handle),
                    last: point,
                };
            }
            Phase::Adjusting { .. } | Phase::Done => {}
        }
    }

    /// 鼠标按下。
    pub fn mouse_down(&mut self, point: (f64, f64)) {
        match &self.phase {
            Phase::Hovering { window } => {
                self.phase = Phase::Pressed {
                    origin: point,
                    window: *window,
                };
            }
            Phase::Adjusting { rect, .. } => {
                // 按在手柄上 → 开始微调；按在别处 → 重新拉一个选区
                if let Some(handle) = handle_at(point, rect, HANDLE_TOLERANCE) {
                    self.phase = Phase::Adjusting {
                        rect: *rect,
                        dragging: Some(handle),
                        last: point,
                    };
                } else {
                    self.phase = Phase::Pressed {
                        origin: point,
                        window: self.window_at(point),
                    };
                }
            }
            _ => {}
        }
    }

    /// 鼠标松开。
    pub fn mouse_up(&mut self, point: (f64, f64)) {
        match &self.phase {
            // 没超过阈值 → 点击命中的窗口；点在空白处则什么也不做
            Phase::Pressed { window, .. } => {
                if let Some(index) = *window {
                    self.finish(Outcome::Window(index));
                } else {
                    self.phase = Phase::Hovering {
                        window: self.window_at(point),
                    };
                }
            }
            Phase::Dragging { origin, .. } => {
                let rect =
                    Rect::from_points(origin.0, origin.1, point.0, point.1).clamped_to(&self.bounds);
                self.phase = Phase::Adjusting {
                    rect,
                    dragging: None,
                    last: point,
                };
            }
            Phase::Adjusting { rect, .. } => {
                self.phase = Phase::Adjusting {
                    rect: *rect,
                    dragging: None,
                    last: point,
                };
            }
            _ => {}
        }
    }

    /// 键盘事件。`shift` 为真时方向键步长 ×10。
    pub fn key_down(&mut self, key: Key, shift: bool) {
        match key {
            Key::Escape => self.finish(Outcome::Cancelled),
            Key::Enter => {
                // 已有选区就确认选区，否则截全屏
                if let Phase::Adjusting { rect, .. } = self.phase {
                    self.finish(Outcome::Region(rect));
                } else {
                    self.finish(Outcome::FullScreen);
                }
            }
            Key::Left | Key::Right | Key::Up | Key::Down => {
                let step = NUDGE_STEP * if shift { NUDGE_FAST_MULTIPLIER } else { 1.0 };
                let (dx, dy) = match key {
                    Key::Left => (-step, 0.0),
                    Key::Right => (step, 0.0),
                    Key::Up => (0.0, -step),
                    Key::Down => (0.0, step),
                    _ => (0.0, 0.0),
                };
                if let Phase::Adjusting { rect, last, .. } = self.phase {
                    self.phase = Phase::Adjusting {
                        rect: rect.offset(dx, dy).clamped_to(&self.bounds),
                        dragging: None,
                        last,
                    };
                }
            }
        }
    }

    /// 直接确认当前选区（平台层的「确认」按钮）。
    pub fn confirm(&mut self) {
        match self.phase {
            Phase::Adjusting { rect, .. } => self.finish(Outcome::Region(rect)),
            Phase::Hovering { window: Some(i) } => self.finish(Outcome::Window(i)),
            _ => self.finish(Outcome::FullScreen),
        }
    }

    fn finish(&mut self, outcome: Outcome) {
        self.phase = Phase::Done;
        self.outcome = Some(outcome);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> Selection {
        Selection::new(
            Rect::new(0.0, 0.0, 1000.0, 800.0),
            vec![
                Rect::new(100.0, 100.0, 200.0, 200.0),
                Rect::new(0.0, 0.0, 1000.0, 800.0),
            ],
        )
    }

    #[test]
    fn click_without_moving_captures_hovered_window() {
        let mut s = setup();
        s.mouse_moved((150.0, 150.0));
        s.mouse_down((150.0, 150.0));
        // 抖动 2pt，仍在阈值内 → 依然算点击
        s.mouse_moved((152.0, 151.0));
        s.mouse_up((152.0, 151.0));
        assert_eq!(s.outcome(), Some(&Outcome::Window(0)));
    }

    #[test]
    fn dragging_past_threshold_becomes_a_region() {
        let mut s = setup();
        s.mouse_moved((150.0, 150.0));
        s.mouse_down((150.0, 150.0));
        s.mouse_moved((160.0, 160.0)); // > 4pt
        s.mouse_up((350.0, 250.0));
        // 拖拽结束后进入可微调状态，而不是直接出结果
        assert!(matches!(s.phase(), Phase::Adjusting { .. }));
        assert_eq!(s.current_rect(), Some(Rect::new(150.0, 150.0, 200.0, 100.0)));
        s.confirm();
        assert_eq!(
            s.outcome(),
            Some(&Outcome::Region(Rect::new(150.0, 150.0, 200.0, 100.0)))
        );
    }

    #[test]
    fn hovering_picks_the_frontmost_window() {
        let mut s = setup();
        // 两个窗口都包含该点，应取 z 序靠前的那个
        s.mouse_moved((150.0, 150.0));
        assert_eq!(s.current_rect(), Some(Rect::new(100.0, 100.0, 200.0, 200.0)));
        // 只有背景窗口包含
        s.mouse_moved((600.0, 600.0));
        assert_eq!(s.current_rect(), Some(Rect::new(0.0, 0.0, 1000.0, 800.0)));
    }

    #[test]
    fn arrow_keys_nudge_by_one_pixel_and_ten_with_shift() {
        let mut s = setup();
        s.mouse_down((100.0, 100.0));
        s.mouse_moved((110.0, 110.0));
        s.mouse_up((300.0, 300.0));
        let before = s.current_rect().unwrap();

        s.key_down(Key::Right, false);
        assert_eq!(s.current_rect().unwrap().x, before.x + 1.0);

        s.key_down(Key::Right, true);
        assert_eq!(s.current_rect().unwrap().x, before.x + 11.0);
    }

    #[test]
    fn nudging_stops_at_screen_edge() {
        let mut s = setup();
        s.mouse_down((0.0, 0.0));
        s.mouse_moved((10.0, 10.0));
        s.mouse_up((100.0, 100.0));
        for _ in 0..50 {
            s.key_down(Key::Left, true);
        }
        // 贴住左边缘就不再往外走
        assert_eq!(s.current_rect().unwrap().x, 0.0);
    }

    #[test]
    fn dragging_a_handle_resizes_the_selection() {
        let mut s = setup();
        s.mouse_down((100.0, 100.0));
        s.mouse_moved((110.0, 110.0));
        s.mouse_up((300.0, 300.0));
        // 抓右下角手柄往外拉 50
        s.mouse_down((300.0, 300.0));
        s.mouse_moved((350.0, 350.0));
        s.mouse_up((350.0, 350.0));
        assert_eq!(s.current_rect(), Some(Rect::new(100.0, 100.0, 250.0, 250.0)));
    }

    #[test]
    fn enter_captures_fullscreen_before_a_selection_exists() {
        let mut s = setup();
        s.key_down(Key::Enter, false);
        assert_eq!(s.outcome(), Some(&Outcome::FullScreen));
    }

    #[test]
    fn escape_cancels_from_any_phase() {
        for prepare in [0, 1, 2] {
            let mut s = setup();
            if prepare >= 1 {
                s.mouse_down((100.0, 100.0));
            }
            if prepare == 2 {
                s.mouse_moved((200.0, 200.0));
            }
            s.key_down(Key::Escape, false);
            assert_eq!(s.outcome(), Some(&Outcome::Cancelled));
        }
    }
}
