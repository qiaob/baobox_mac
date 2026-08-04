//! 窗口管理（Windows）：把当前窗口摆到半屏 / 四分屏 / 居中 / 另一块屏。
//!
//! 几何全在 `baobox_core::layout`（三平台共用），这里只做三件事：
//! 找到当前窗口、问出每块屏的可用区域、把窗口挪过去。
//!
//! # 阴影边距：看到的和 `SetWindowPos` 要的不是一回事
//!
//! Win10 起窗口带一圈**不可见的阴影边距**，`GetWindowRect` 把它算在内。
//! 直接拿算好的目标矩形去 `SetWindowPos`，用户看到的窗口会比预期**小一圈**，
//! 而且两个半屏窗口中间会多出一条缝 —— 明明代码里算的是严丝合缝。
//!
//! 正确做法：拿 `DWMWA_EXTENDED_FRAME_BOUNDS`（可见边界）与 `GetWindowRect`
//! （含阴影）作差得到那一圈的厚度，摆位置时把目标矩形**外扩**这么多。
//! 这段算术是纯的，[`inflate_for_shadow`] 单独测。
//!
//! # 先取消最大化，再摆
//!
//! 最大化的窗口对 `SetWindowPos` 的反应是「位置变了但仍然是最大化状态」——
//! 用户下次点还原会跳回一个莫名其妙的地方。所以先 `SW_RESTORE`。

#![cfg(windows)]

use baobox_core::geometry::Rect;
use windows::Win32::Foundation::{HWND, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetWindowRect, IsIconic, IsZoomed, SetWindowPos, ShowWindow, HWND_TOP,
    SWP_NOACTIVATE, SWP_NOZORDER, SW_RESTORE,
};

/// 那一圈不可见阴影的厚度（左、上、右、下）。
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Shadow {
    /// 左边多出来多少
    pub left: f64,
    /// 上边多出来多少
    pub top: f64,
    /// 右边多出来多少
    pub right: f64,
    /// 下边多出来多少
    pub bottom: f64,
}

/// 把「希望看到的矩形」外扩成「该传给 `SetWindowPos` 的矩形」。
///
/// 不做这一步的话，用户看到的窗口会比预期小一圈，两个半屏窗口中间还会多一条缝。
pub fn inflate_for_shadow(visible: &Rect, shadow: &Shadow) -> Rect {
    Rect::new(
        visible.x - shadow.left,
        visible.y - shadow.top,
        visible.w + shadow.left + shadow.right,
        visible.h + shadow.top + shadow.bottom,
    )
}

/// 当前在最前面的那个窗口。
///
/// 拿不到（桌面获得焦点、或者焦点在别的桌面上）时返回 `None`。
pub fn foreground() -> Option<HWND> {
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        return None;
    }
    // 最小化的窗口没有有意义的位置，摆它只会让它在任务栏里原地不动
    if unsafe { IsIconic(hwnd) }.as_bool() {
        return None;
    }
    Some(hwnd)
}

/// 一个窗口现在的**可见**矩形，以及它那一圈阴影有多厚。
pub fn geometry(hwnd: HWND) -> Option<(Rect, Shadow)> {
    let outer = window_rect(hwnd)?;
    let visible = crate::gdi::visible_frame(hwnd).unwrap_or(outer);
    let shadow = Shadow {
        left: visible.x - outer.x,
        top: visible.y - outer.y,
        right: outer.right() - visible.right(),
        bottom: outer.bottom() - visible.bottom(),
    };
    Some((visible, shadow))
}

fn window_rect(hwnd: HWND) -> Option<Rect> {
    let mut rect = RECT::default();
    unsafe { GetWindowRect(hwnd, &mut rect) }.ok()?;
    Some(Rect::new(
        rect.left as f64,
        rect.top as f64,
        (rect.right - rect.left) as f64,
        (rect.bottom - rect.top) as f64,
    ))
}

/// 每块屏的**可用区域**（`rcWork`，已经扣掉任务栏）。
///
/// 用 `rcWork` 而不是 `rcMonitor`：后者是整块屏，半屏窗口会有一半压在任务栏底下。
/// 而且任务栏可以只在某一块屏上，所以这个值必须逐屏取。
pub fn work_areas() -> Vec<Rect> {
    let mut found: Vec<Rect> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(
            None,
            None,
            Some(collect_monitor),
            LPARAM(&mut found as *mut Vec<Rect> as isize),
        );
    }
    found
}

unsafe extern "system" fn collect_monitor(
    monitor: HMONITOR,
    _dc: HDC,
    _rect: *mut RECT,
    lparam: LPARAM,
) -> windows::Win32::Foundation::BOOL {
    use windows::Win32::Foundation::TRUE;
    let found = &mut *(lparam.0 as *mut Vec<Rect>);
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if GetMonitorInfoW(monitor, &mut info).as_bool() {
        let work = info.rcWork;
        found.push(Rect::new(
            work.left as f64,
            work.top as f64,
            (work.right - work.left) as f64,
            (work.bottom - work.top) as f64,
        ));
    }
    TRUE
}

/// 把窗口摆到目标位置。`target` 是**希望看到的**矩形。
pub fn place(hwnd: HWND, target: &Rect, shadow: &Shadow) -> Result<(), String> {
    unsafe {
        // 最大化的窗口挪了位置仍然是最大化状态，下次还原会跳到莫名其妙的地方
        if IsZoomed(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let outer = inflate_for_shadow(target, shadow);
        SetWindowPos(
            hwnd,
            HWND_TOP,
            outer.x.round() as i32,
            outer.y.round() as i32,
            outer.w.round() as i32,
            outer.h.round() as i32,
            SWP_NOACTIVATE | SWP_NOZORDER,
        )
        .map_err(|e| format!("摆放窗口失败：{e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_window_without_shadow_is_placed_exactly_where_asked() {
        let target = Rect::new(0.0, 0.0, 960.0, 1040.0);
        assert_eq!(inflate_for_shadow(&target, &Shadow::default()), target);
    }

    #[test]
    fn the_invisible_border_is_added_back_so_the_visible_edge_lands_right() {
        // Win10 典型值：左右下各 7 像素，上边 0
        let shadow = Shadow {
            left: 7.0,
            top: 0.0,
            right: 7.0,
            bottom: 7.0,
        };
        let target = Rect::new(0.0, 0.0, 960.0, 1040.0);
        let outer = inflate_for_shadow(&target, &shadow);
        assert_eq!(outer, Rect::new(-7.0, 0.0, 974.0, 1047.0));
        // 关键：外扩之后，可见边界正好回到目标
        assert_eq!(outer.x + shadow.left, target.x);
        assert_eq!(outer.right() - shadow.right, target.right());
    }

    #[test]
    fn two_half_screen_windows_have_no_visible_seam() {
        // 不补阴影的话，两个半屏窗口中间会多出一条 14 像素的缝 ——
        // 明明代码里算的是严丝合缝
        let shadow = Shadow {
            left: 7.0,
            top: 0.0,
            right: 7.0,
            bottom: 7.0,
        };
        let work = Rect::new(0.0, 0.0, 1920.0, 1040.0);
        let left = baobox_core::layout::target(
            baobox_core::layout::Layout::Left,
            &work,
            &work,
            0.0,
        );
        let right = baobox_core::layout::target(
            baobox_core::layout::Layout::Right,
            &work,
            &work,
            0.0,
        );
        let left_outer = inflate_for_shadow(&left, &shadow);
        let right_outer = inflate_for_shadow(&right, &shadow);
        // 可见边界严丝合缝
        assert_eq!(left_outer.right() - shadow.right, right_outer.x + shadow.left);
    }
}
