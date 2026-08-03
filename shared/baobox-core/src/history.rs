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

/// 索引文件的字段分隔符。制表符不可能出现在路径或 id 里，用它比逗号安全。
const FIELD: char = '\t';

/// 把历史编码成一段文本，供平台层落盘。
///
/// # 为什么不是 JSON
///
/// 这个 crate 是零依赖的，为了一个只有五个字段的索引引进 serde 不划算；
/// 手写 JSON 转义又容易在路径里带引号时出错。一行一条、制表符分隔的格式
/// 写起来不会错，坏了一行也只丢一条记录（见 [`decode_index`]）。
pub fn encode_index(history: &History) -> String {
    let mut out = String::new();
    for entry in history.entries() {
        // 含制表符或换行的路径会撑破格式；这种路径极罕见，跳过比写出坏文件好
        if [entry.id.as_str(), entry.path.as_str()]
            .iter()
            .any(|field| field.contains(FIELD) || field.contains('\n'))
        {
            continue;
        }
        out.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\n",
            entry.id, entry.path, entry.width, entry.height, entry.created_at
        ));
    }
    out
}

/// 从文本读回历史。
///
/// **坏行只跳过，不报错**：索引是缓存，为了一条读不懂的记录让整个历史消失
/// 是最糟的选择（用户会以为截图全丢了）。
pub fn decode_index(text: &str, limit: usize) -> History {
    let mut history = History::new(limit);
    let mut entries = Vec::new();
    for line in text.lines() {
        let fields: Vec<&str> = line.split(FIELD).collect();
        if fields.len() != 5 {
            continue;
        }
        let (Ok(width), Ok(height), Ok(created_at)) = (
            fields[2].parse::<u32>(),
            fields[3].parse::<u32>(),
            fields[4].parse::<i64>(),
        ) else {
            continue;
        };
        if fields[0].is_empty() || fields[1].is_empty() {
            continue;
        }
        entries.push(Entry {
            id: fields[0].to_string(),
            path: fields[1].to_string(),
            width,
            height,
            created_at,
        });
    }
    // 文件里已经是「最新在前」，按原顺序追加
    entries.reverse();
    for entry in entries {
        history.push(entry);
    }
    history
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
    fn an_index_survives_a_round_trip_with_order_intact() {
        let mut h = History::new(5);
        for id in ["a", "b", "c"] {
            h.push(entry(id));
        }
        let restored = decode_index(&encode_index(&h), 5);
        assert_eq!(restored.entries().len(), 3);
        // 最新的仍在最前
        assert_eq!(restored.entries()[0].id, "c");
        assert_eq!(restored.entries()[2].id, "a");
        assert_eq!(restored.entries()[0], h.entries()[0]);
    }

    #[test]
    fn a_corrupt_line_costs_one_record_not_the_whole_history() {
        let text = "a\t/tmp/a.png\t100\t100\t0\n\
                    这一行是垃圾\n\
                    b\t/tmp/b.png\t不是数字\t100\t0\n\
                    c\t/tmp/c.png\t100\t100\t0\n";
        let restored = decode_index(text, 10);
        let ids: Vec<&str> = restored.entries().iter().map(|e| e.id.as_str()).collect();
        // 文件里是「最新在前」，所以 a 比 c 新；中间两行坏掉的被跳过
        assert_eq!(ids, vec!["a", "c"], "坏行跳过，好行照读");
    }

    #[test]
    fn decoding_still_honours_the_limit() {
        let mut h = History::new(100);
        for id in ["a", "b", "c", "d", "e"] {
            h.push(entry(id));
        }
        let restored = decode_index(&encode_index(&h), 2);
        assert_eq!(restored.entries().len(), 2);
        assert_eq!(restored.entries()[0].id, "e", "留下的应是最新的");
    }

    #[test]
    fn a_path_with_a_tab_is_skipped_rather_than_corrupting_the_file() {
        let mut h = History::new(5);
        h.push(Entry {
            id: "bad".to_string(),
            path: "/tmp/a\tb.png".to_string(),
            width: 1,
            height: 1,
            created_at: 0,
        });
        h.push(entry("good"));
        let text = encode_index(&h);
        assert!(!text.contains("bad"));
        assert_eq!(decode_index(&text, 5).entries().len(), 1);
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
