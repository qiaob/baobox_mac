//! 截图历史：定量环形存储。
//!
//! 与「保存到磁盘的文件」是两件相互独立的事 —— 即便关掉自动保存，每次截图也都进历史，
//! 便于找回。三平台共用同一套淘汰规则。

/// 一条历史记录。图像本身由平台层存放，这里只记元数据与它的落盘位置。
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// 稳定标识
    pub id: String,
    /// 图像文件路径（平台层写入）
    pub path: String,
    /// 宽（像素）
    pub width: u32,
    /// 高（像素）
    pub height: u32,
    /// 创建时刻（Unix 秒）
    pub created_at: i64,
}

/// 定量历史：超出上限时淘汰最旧的。
#[derive(Debug, Clone)]
pub struct History {
    entries: Vec<Entry>,
    limit: usize,
}

impl History {
    /// 默认保留张数，与 macOS 侧一致。
    pub const DEFAULT_LIMIT: usize = 20;

    /// 新建。`limit` 为 0 时按默认值处理（不允许「一张都不留」这种一定是配错的值）。
    pub fn new(limit: usize) -> Self {
        Self {
            entries: Vec::new(),
            limit: if limit == 0 { Self::DEFAULT_LIMIT } else { limit },
        }
    }

    /// 当前记录，最新的在前。
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// 当前上限。
    pub fn limit(&self) -> usize {
        self.limit
    }

    /// 记一条，返回被淘汰的记录（调用方据此删掉对应文件）。
    pub fn push(&mut self, entry: Entry) -> Vec<Entry> {
        self.entries.insert(0, entry);
        self.trim()
    }

    /// 按 id 删除。返回是否删掉了。
    pub fn remove(&mut self, id: &str) -> Option<Entry> {
        let index = self.entries.iter().position(|e| e.id == id)?;
        Some(self.entries.remove(index))
    }

    /// 清空，返回全部记录供调用方删文件。
    pub fn clear(&mut self) -> Vec<Entry> {
        std::mem::take(&mut self.entries)
    }

    /// 调整上限，返回因缩小上限而被淘汰的记录。
    pub fn set_limit(&mut self, limit: usize) -> Vec<Entry> {
        self.limit = if limit == 0 { Self::DEFAULT_LIMIT } else { limit };
        self.trim()
    }

    fn trim(&mut self) -> Vec<Entry> {
        if self.entries.len() <= self.limit {
            return Vec::new();
        }
        self.entries.split_off(self.limit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str) -> Entry {
        Entry {
            id: id.to_string(),
            path: format!("/tmp/{id}.png"),
            width: 100,
            height: 100,
            created_at: 0,
        }
    }

    #[test]
    fn newest_first_and_oldest_evicted() {
        let mut h = History::new(3);
        for id in ["a", "b", "c"] {
            assert!(h.push(entry(id)).is_empty());
        }
        assert_eq!(h.entries()[0].id, "c", "最新的应在最前");

        let evicted = h.push(entry("d"));
        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].id, "a", "淘汰的应是最旧的那条");
        assert_eq!(h.entries().len(), 3);
    }

    #[test]
    fn zero_limit_falls_back_to_default() {
        let h = History::new(0);
        assert_eq!(h.limit(), History::DEFAULT_LIMIT);
    }

    #[test]
    fn shrinking_the_limit_evicts_immediately() {
        let mut h = History::new(10);
        for id in ["a", "b", "c", "d"] {
            h.push(entry(id));
        }
        let evicted = h.set_limit(2);
        assert_eq!(evicted.len(), 2);
        assert_eq!(h.entries().len(), 2);
        // 留下的是最新的两条
        assert_eq!(h.entries()[0].id, "d");
        assert_eq!(h.entries()[1].id, "c");
    }

    #[test]
    fn remove_and_clear_return_what_was_dropped() {
        let mut h = History::new(5);
        h.push(entry("a"));
        h.push(entry("b"));
        assert_eq!(h.remove("a").unwrap().id, "a");
        assert!(h.remove("nope").is_none());
        let all = h.clear();
        assert_eq!(all.len(), 1);
        assert!(h.entries().is_empty());
    }
}
