//! 全局快捷键里平台无关的那一半。
//!
//! 「把组合注册进系统」两个平台各写各的（X11 `GrabKey` / Win32 `RegisterHotKey`），
//! 留在平台层的 `hotkeys.rs`；注册完要告诉用户什么 —— 成功了几个、哪几个没注册上、
//! 为什么 —— 两边是同一件事、同一句话，以前却各有一份逐字相同的 [`Registration`]，
//! 收到这里只留一份。
//!
//! 规格与「用户实际绑定的组合」怎么合起来在 [`crate::ToolRegistry::resolved_hotkeys`]。

/// 一次注册的结果。
pub struct Registration {
    /// 成功注册了几个
    pub bound: usize,
    /// 没能注册的，`(动作 id, 原因)`。多半是被别的程序占了
    pub conflicts: Vec<(String, String)>,
}

impl Registration {
    /// 有没有需要提示用户的问题。
    pub fn has_problems(&self) -> bool {
        !self.conflicts.is_empty()
    }

    /// 一句给用户看的话。
    pub fn describe(&self) -> String {
        if self.conflicts.is_empty() {
            return format!("已注册 {} 个全局快捷键。", self.bound);
        }
        let details: Vec<String> = self
            .conflicts
            .iter()
            .map(|(id, why)| format!("  {id}：{why}"))
            .collect();
        format!(
            "已注册 {} 个全局快捷键，{} 个没能注册（多半被别的程序占了，可在设置里换一个）：\n{}",
            self.bound,
            self.conflicts.len(),
            details.join("\n")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_registration_report_reads_like_a_sentence() {
        let clean = Registration {
            bound: 3,
            conflicts: Vec::new(),
        };
        assert!(!clean.has_problems());
        assert!(clean.describe().contains('3'));

        let clashed = Registration {
            bound: 1,
            conflicts: vec![("screenshot.capture".into(), "BadAccess".into())],
        };
        assert!(clashed.has_problems());
        let text = clashed.describe();
        assert!(text.contains("screenshot.capture"));
        assert!(text.contains("设置"), "要告诉用户去哪儿改");
    }
}
