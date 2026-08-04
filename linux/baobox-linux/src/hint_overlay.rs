//! 标签覆盖层（Linux）：把字母标签画在所有窗口之上，收键盘。
//!
//! 交互规则全在 `baobox_core::hints::Session`，这里只做两件事：
//! 把标签画出来、把按键喂给它。
//!
//! # 为什么借 GTK 而不是像截图覆盖层那样手绘 X11
//!
//! 截图覆盖层只画矩形，X11 核心绘图够用；标签要画**文字**，
//! 而 X11 核心字体连中文都成问题，标签底板还要圆角与半透明。
//! GTK 已经为设置窗口引进来了，借它这些全是白拿的。
//!
//! # 一个窗口跑完整场，不是每按一个键重建一次
//!
//! 重建的话屏幕会闪，而且每次都要重新抓键盘 —— 中间那几十毫秒里
//! 用户打的字会直接落到底下的程序里去。

use baobox_core::hints::{Hint, Outcome, Session};
use gtk::gdk;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

/// 标签底板的内边距（像素）。
const PAD: f64 = 3.0;

/// 标签字号。
const FONT_SIZE: f64 = 13.0;

/// 跑一整场：显示标签、收键盘，返回用户点掉的那些。
///
/// 必须在 GTK 主线程上调用。
pub fn run(session: &mut Session) -> Result<Vec<Hint>, String> {
    if !gtk::is_initialized() && gtk::init().is_err() {
        return Err("GTK 起不来，键盘点击用不了".to_string());
    }

    let picked: Rc<RefCell<Vec<Hint>>> = Rc::new(RefCell::new(Vec::new()));
    let state = Rc::new(RefCell::new(session.clone()));

    let window = gtk::Window::new(gtk::WindowType::Popup);
    window.set_app_paintable(true);
    window.set_decorated(false);
    window.set_keep_above(true);
    window.set_skip_taskbar_hint(true);
    window.set_accept_focus(true);
    // 铺满整块屏幕 —— 标签的坐标是屏幕坐标
    // 没有合成器时拿不到 RGBA visual，那时窗口是不透明的（能用，只是难看）
    if let Some(visual) = gdk::Screen::default().and_then(|s| s.rgba_visual()) {
        window.set_visual(Some(&visual));
    }
    // 铺满整块屏幕 —— 标签的坐标是屏幕坐标
    {
        let screen = crate::x11capture::X11Session::open()
            .map(|s| s.screen_rect())
            .unwrap_or(baobox_core::geometry::Rect::new(0.0, 0.0, 1920.0, 1080.0));
        window.move_(screen.x as i32, screen.y as i32);
        window.resize(screen.w as i32, screen.h as i32);
    }

    {
        let state = Rc::clone(&state);
        window.connect_draw(move |_, cr| {
            draw(cr, &state.borrow());
            glib::Propagation::Proceed
        });
    }

    {
        let state = Rc::clone(&state);
        let picked = Rc::clone(&picked);
        let window_ref = window.clone();
        window.connect_key_press_event(move |_, event| {
            let key = event.keyval();
            if key == gdk::keys::constants::Escape {
                gtk::main_quit();
                return glib::Propagation::Stop;
            }
            if key == gdk::keys::constants::BackSpace {
                if state.borrow_mut().backspace() == Outcome::Cancel {
                    gtk::main_quit();
                }
                window_ref.queue_draw();
                return glib::Propagation::Stop;
            }
            let Some(c) = key.to_unicode() else {
                return glib::Propagation::Stop;
            };
            match state.borrow_mut().push(c) {
                Outcome::Activate(hit) => {
                    picked.borrow_mut().push(hit);
                    // 连续点击时留着继续；否则这一下就收工
                    if !state.borrow().is_continuous() {
                        gtk::main_quit();
                    }
                }
                Outcome::Cancel => gtk::main_quit(),
                Outcome::Filtering(_) => {}
            }
            window_ref.queue_draw();
            glib::Propagation::Stop
        });
    }

    window.connect_delete_event(|_, _| {
        gtk::main_quit();
        glib::Propagation::Stop
    });

    window.show_all();
    window.present();
    // 抓住键盘：不抓的话用户打的字会漏到底下的程序里去
    grab_keyboard(&window);
    gtk::main();

    unsafe { window.destroy() };
    while gtk::events_pending() {
        gtk::main_iteration_do(false);
    }
    let out = picked.borrow().clone();
    Ok(out)
}

/// 抓键盘。抓不到也照跑 —— 抓不到时按键会漏下去，但总比什么都不显示好。
fn grab_keyboard(window: &gtk::Window) {
    let Some(gdk_window) = window.window() else {
        return;
    };
    let Some(display) = gdk::Display::default() else {
        return;
    };
    let Some(seat) = display.default_seat() else {
        return;
    };
    let _ = seat.grab(
        &gdk_window,
        gdk::SeatCapabilities::KEYBOARD,
        true,
        None,
        None,
        None,
    );
}

/// 把标签画出来。
fn draw(cr: &gtk::cairo::Context, session: &Session) {
    // 整屏压暗一点点：标签才看得清，而底下的内容还认得出
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.25);
    let _ = cr.set_operator(gtk::cairo::Operator::Source);
    let _ = cr.paint();
    let _ = cr.set_operator(gtk::cairo::Operator::Over);

    cr.select_font_face(
        "monospace",
        gtk::cairo::FontSlant::Normal,
        gtk::cairo::FontWeight::Bold,
    );
    cr.set_font_size(FONT_SIZE);

    let typed = session.typed();
    for hint in session.hints() {
        let dim = !hint.tag.starts_with(typed);
        let text = &hint.tag;
        let extents = match cr.text_extents(text) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let w = extents.width() + PAD * 2.0;
        let h = FONT_SIZE + PAD * 2.0;
        // 标签摆在元素中心的左上方一点，别把元素本身盖住
        let x = hint.target.x - w / 2.0;
        let y = hint.target.y - h / 2.0;

        // 底板：没匹配上的淡出去，而不是直接不画 ——
        // 全都还在的话，用户能看出「我打的这个字缩小了多少范围」
        if dim {
            cr.set_source_rgba(0.35, 0.35, 0.35, 0.55);
        } else {
            cr.set_source_rgba(0.09, 0.64, 0.60, 0.95); // 与设计稿的 accent 同色
        }
        cr.rectangle(x, y, w, h);
        let _ = cr.fill();

        cr.set_source_rgba(1.0, 1.0, 1.0, if dim { 0.5 } else { 1.0 });
        cr.move_to(x + PAD, y + h - PAD - 2.0);
        let _ = cr.show_text(text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use baobox_core::hints::{assign, Target};

    fn session() -> Session {
        let targets = (0..5)
            .map(|n| Target {
                x: n as f64 * 100.0,
                y: n as f64 * 50.0,
                label: format!("按钮 {n}"),
            })
            .collect();
        Session::new(assign(targets, "abc"), "abc", false)
    }

    #[test]
    fn drawing_does_not_panic_on_an_empty_or_filtered_session() {
        // 画布用内存 surface，不需要图形环境
        let surface = gtk::cairo::ImageSurface::create(gtk::cairo::Format::ARgb32, 200, 200)
            .expect("建不出画布");
        let cr = gtk::cairo::Context::new(&surface).expect("建不出上下文");

        draw(&cr, &session());

        let mut narrowed = session();
        narrowed.push('a');
        draw(&cr, &narrowed);

        let empty = Session::new(Vec::new(), "abc", false);
        draw(&cr, &empty);
    }

    #[test]
    fn the_label_padding_leaves_the_text_readable() {
        assert!(PAD > 0.0);
        assert!(FONT_SIZE >= 10.0, "太小的话密密麻麻一片看不清");
    }
}
