//! 剪贴板历史：条目模型、去重、淘汰、搜索、片段。
//!
//! 与 macOS 侧 `ClipboardItem.swift` + `ClipboardStore.swift` 同一套语义，
//! 但这里不含任何监听与磁盘 IO —— 平台层负责「怎么拿到内容、存到哪」，
//! 规则在这里，三个平台不会各自漂移。
//!
//! # 三条最容易做错的规则
//!
//! 1. **去重要保留原 id、只刷新时间戳**。换成「删旧的插新的」的话，
//!    收藏状态、片段标题、关键字会跟着旧条目一起没掉。
//! 2. **收藏（含片段）不参与任何淘汰**：不被数量上限挤掉、不被过期清掉、
//!    不被「清空」删掉。片段就是手工创建的收藏，靠的正是这条命。
//! 3. **敏感内容默认根本不入库**。用户显式打开开关之后才记，
//!    而且面板里默认打码。

/// 条目类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// 纯文本
    Text,
    /// 看起来是个链接的文本（单独分类只为了筛选方便）
    Link,
    /// 图片，像素存在平台层给的文件里
    Image,
    /// 文件路径（多个以换行分隔）
    File,
}

impl Kind {
    /// 存进索引文件时的标记。
    pub fn tag(&self) -> &'static str {
        match self {
            Kind::Text => "text",
            Kind::Link => "link",
            Kind::Image => "image",
            Kind::File => "file",
        }
    }

    /// 从索引文件的标记读回来。认不出来的当纯文本 —— 新版本加了类型时，
    /// 老版本读到它应当降级显示，而不是把整条记录丢掉。
    pub fn from_tag(tag: &str) -> Kind {
        match tag {
            "link" => Kind::Link,
            "image" => Kind::Image,
            "file" => Kind::File,
            _ => Kind::Text,
        }
    }
}

/// 一条剪贴板记录。
#[derive(Debug, Clone, PartialEq)]
pub struct Item {
    /// 稳定标识。去重时**不换**，否则收藏与片段信息会跟着丢
    pub id: String,
    /// 类型
    pub kind: Kind,
    /// 文本内容；图片条目为空
    pub text: String,
    /// 图片文件名（相对平台层的图片目录）
    pub image_file: String,
    /// 来源程序名，取不到就空着
    pub source: String,
    /// 创建 / 最近一次重复出现的时刻（Unix 秒）
    pub created_at: i64,
    /// 收藏。收藏的条目不参与任何淘汰
    pub pinned: bool,
    /// 来源把它标成了敏感（密码管理器复制的密码）
    pub concealed: bool,
    /// 片段的展示名
    pub title: String,
    /// 片段的关键字触发词（不含前缀）
    pub keyword: String,
}

impl Item {
    /// 造一条普通的文本记录。
    pub fn text(id: &str, text: &str, created_at: i64) -> Item {
        Item {
            id: id.to_string(),
            kind: if looks_like_link(text) {
                Kind::Link
            } else {
                Kind::Text
            },
            text: text.to_string(),
            image_file: String::new(),
            source: String::new(),
            created_at,
            pinned: false,
            concealed: false,
            title: String::new(),
            keyword: String::new(),
        }
    }

    /// 片段 = 手工创建的收藏条目。
    ///
    /// 不另开一份数据源：收藏这条线已经保证了「不被清空 / 过期 / 超限淘汰」，
    /// 片段要的生命周期与它完全一致。
    pub fn is_snippet(&self) -> bool {
        self.pinned && (!self.title.is_empty() || !self.keyword.is_empty())
    }

    /// 去重用的内容签名。图片按文件名，其余按「类型 + 文本」。
    pub fn signature(&self) -> String {
        match self.kind {
            Kind::Image => format!("image:{}", self.image_file),
            _ => format!("{}:{}", self.kind.tag(), self.text),
        }
    }

    /// 列表里显示的一行标题。
    ///
    /// 片段用它的名字；其余用内容首行。敏感内容打码 —— 面板可能被人从背后看到。
    pub fn display_title(&self) -> String {
        if !self.title.is_empty() {
            return self.title.clone();
        }
        if self.concealed {
            return "••••••••".to_string();
        }
        match self.kind {
            Kind::Image => "（图片）".to_string(),
            _ => {
                let first = self.text.lines().next().unwrap_or("").trim();
                if first.is_empty() {
                    "（空白）".to_string()
                } else {
                    first.to_string()
                }
            }
        }
    }
}

/// 看起来像个链接吗。
///
/// 只认 http/https —— `mailto:` 之类不值得单独分一类，
/// 而把「凡是带冒号的都算链接」会把 `note: 见下` 这种普通文本也归错。
pub fn looks_like_link(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.contains(char::is_whitespace) {
        return false;
    }
    trimmed.starts_with("http://") || trimmed.starts_with("https://")
}

/// 面板上的筛选。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Filter {
    /// 全部
    All,
    /// 只看文本
    Text,
    /// 只看链接
    Link,
    /// 只看图片
    Image,
    /// 只看文件
    File,
    /// 只看收藏（含片段）
    Pinned,
    /// 只看片段
    Snippet,
}

impl Filter {
    /// 这一项过得了筛选吗。
    pub fn accepts(&self, item: &Item) -> bool {
        match self {
            Filter::All => true,
            Filter::Text => item.kind == Kind::Text,
            Filter::Link => item.kind == Kind::Link,
            Filter::Image => item.kind == Kind::Image,
            Filter::File => item.kind == Kind::File,
            Filter::Pinned => item.pinned,
            Filter::Snippet => item.is_snippet(),
        }
    }
}

/// 剪贴板历史。
#[derive(Debug, Clone)]
pub struct Store {
    items: Vec<Item>,
    limit: usize,
}

impl Store {
    /// 默认保留条数，与 macOS 侧一致。
    pub const DEFAULT_LIMIT: usize = 200;

    /// 新建。`limit` 为 0 时按默认值处理（「一条都不留」一定是配错了）。
    pub fn new(limit: usize) -> Self {
        Self {
            items: Vec::new(),
            limit: if limit == 0 { Self::DEFAULT_LIMIT } else { limit },
        }
    }

    /// 全部条目，收藏在前、其余按时间倒序。
    pub fn items(&self) -> &[Item] {
        &self.items
    }

    /// 当前上限。
    pub fn limit(&self) -> usize {
        self.limit
    }

    /// 记一条。
    ///
    /// 内容与已有条目重复时**不新增**：把原条目的时间戳刷新并挪到最前，
    /// **id、收藏状态、片段信息原样保留**。返回因超限被淘汰的条目
    /// （调用方据此删掉对应的图片文件）。
    pub fn add(&mut self, item: Item) -> Vec<Item> {
        let signature = item.signature();
        if let Some(index) = self.items.iter().position(|e| e.signature() == signature) {
            self.items[index].created_at = item.created_at;
            // 来源可能变了（同一段文字从别的程序复制），刷新它
            if !item.source.is_empty() {
                self.items[index].source = item.source;
            }
            self.sort();
            return Vec::new();
        }
        self.items.push(item);
        self.sort();
        self.enforce_limit()
    }

    /// 手工创建一个片段，返回它的 id。
    pub fn add_snippet(&mut self, id: &str, title: &str, content: &str, keyword: &str, now: i64) {
        let mut item = Item::text(id, content, now);
        item.pinned = true;
        item.title = title.to_string();
        item.keyword = normalize_keyword(keyword);
        self.items.push(item);
        self.sort();
    }

    /// 切换收藏。
    pub fn toggle_pin(&mut self, id: &str) -> bool {
        let Some(item) = self.items.iter_mut().find(|e| e.id == id) else {
            return false;
        };
        item.pinned = !item.pinned;
        self.sort();
        true
    }

    /// 删一条。
    pub fn remove(&mut self, id: &str) -> Option<Item> {
        let index = self.items.iter().position(|e| e.id == id)?;
        Some(self.items.remove(index))
    }

    /// 清空。**收藏与片段留着** —— 用户点「清空」想清的是历史，不是自己攒的东西。
    pub fn clear(&mut self) -> Vec<Item> {
        let (kept, dropped): (Vec<Item>, Vec<Item>) =
            std::mem::take(&mut self.items).into_iter().partition(|e| e.pinned);
        self.items = kept;
        dropped
    }

    /// 删掉所有敏感条目（用户关掉「记录敏感内容」时调）。
    pub fn remove_concealed(&mut self) -> Vec<Item> {
        let (kept, dropped): (Vec<Item>, Vec<Item>) = std::mem::take(&mut self.items)
            .into_iter()
            .partition(|e| !e.concealed);
        self.items = kept;
        dropped
    }

    /// 清掉超过 `days` 天的条目。`days` 为 0 表示不过期。收藏不受影响。
    pub fn prune_expired(&mut self, days: i64, now: i64) -> Vec<Item> {
        if days <= 0 {
            return Vec::new();
        }
        let cutoff = now - days * 86_400;
        let (kept, dropped): (Vec<Item>, Vec<Item>) = std::mem::take(&mut self.items)
            .into_iter()
            .partition(|e| e.pinned || e.created_at >= cutoff);
        self.items = kept;
        dropped
    }

    /// 调整上限，返回因缩小上限被淘汰的条目。
    pub fn set_limit(&mut self, limit: usize) -> Vec<Item> {
        self.limit = if limit == 0 { Self::DEFAULT_LIMIT } else { limit };
        self.enforce_limit()
    }

    /// 按关键词与筛选取条目。
    ///
    /// 关键词大小写不敏感，同时匹配标题与内容。空关键词只做筛选。
    pub fn search(&self, query: &str, filter: Filter) -> Vec<&Item> {
        let needle = query.trim().to_lowercase();
        self.items
            .iter()
            .filter(|item| filter.accepts(item))
            .filter(|item| {
                if needle.is_empty() {
                    return true;
                }
                // 敏感内容不参与内容搜索 —— 否则可以用搜索把打码的密码试出来
                if item.concealed {
                    return item.title.to_lowercase().contains(&needle);
                }
                item.text.to_lowercase().contains(&needle)
                    || item.title.to_lowercase().contains(&needle)
            })
            .collect()
    }

    /// 按关键字找片段（关键字展开用）。
    pub fn snippet_for_keyword(&self, keyword: &str) -> Option<&Item> {
        let needle = normalize_keyword(keyword);
        if needle.is_empty() {
            return None;
        }
        self.items
            .iter()
            .find(|item| item.is_snippet() && item.keyword == needle)
    }

    /// 全部片段的关键字，供展开器建触发表。
    pub fn snippet_keywords(&self) -> Vec<&str> {
        self.items
            .iter()
            .filter(|item| item.is_snippet() && !item.keyword.is_empty())
            .map(|item| item.keyword.as_str())
            .collect()
    }

    /// 直接放一批条目进来（从磁盘读回时用）。
    pub fn replace_all(&mut self, items: Vec<Item>) {
        self.items = items;
        self.sort();
        let _ = self.enforce_limit();
    }

    /// 收藏在前，各自按时间倒序。
    fn sort(&mut self) {
        self.items.sort_by(|a, b| {
            b.pinned
                .cmp(&a.pinned)
                .then(b.created_at.cmp(&a.created_at))
        });
    }

    /// 超限时从**最旧的非收藏条目**开始淘汰。
    fn enforce_limit(&mut self) -> Vec<Item> {
        let unpinned = self.items.iter().filter(|e| !e.pinned).count();
        if unpinned <= self.limit {
            return Vec::new();
        }
        let mut overflow = unpinned - self.limit;
        let mut dropped = Vec::new();
        // 从后往前删：排序之后越靠后越旧
        let mut index = self.items.len();
        while index > 0 && overflow > 0 {
            index -= 1;
            if !self.items[index].pinned {
                dropped.push(self.items.remove(index));
                overflow -= 1;
            }
        }
        dropped
    }
}

/// 索引文件的字段分隔符。
const FIELD: char = '\t';

/// 把历史编码成一段文本，供平台层落盘。
///
/// # 为什么要转义
///
/// 剪贴板里什么都有：多行日志、带制表符的表格、Windows 的 `\r\n`。
/// 直接按行按制表符切会把一条记录切成好几条，而且下次读回来就乱套了。
/// 所以内容里的 `\` `\n` `\r` `\t` 一律转义，一条记录**保证只占一行**。
///
/// 不用 JSON 是因为这个 crate 零依赖，而手写 JSON 转义在内容含引号时
/// 更容易出错；行式格式坏了一行也只丢一条记录。
pub fn encode_index(store: &Store) -> String {
    let mut out = String::new();
    for item in store.items() {
        let fields = [
            item.id.as_str(),
            item.kind.tag(),
            item.text.as_str(),
            item.image_file.as_str(),
            item.source.as_str(),
            &item.created_at.to_string(),
            if item.pinned { "1" } else { "0" },
            if item.concealed { "1" } else { "0" },
            item.title.as_str(),
            item.keyword.as_str(),
        ];
        let escaped: Vec<String> = fields.iter().map(|f| escape(f)).collect();
        out.push_str(&escaped.join("\t"));
        out.push('\n');
    }
    out
}

/// 从文本读回历史。
///
/// **坏行只跳过，不报错**：历史是用户攒下来的东西，为了一条读不懂的记录
/// 让整份历史消失是最糟的选择。
pub fn decode_index(text: &str, limit: usize) -> Store {
    let mut items = Vec::new();
    for line in text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split(FIELD).collect();
        if fields.len() < 10 {
            continue;
        }
        let Ok(created_at) = unescape(fields[5]).parse::<i64>() else {
            continue;
        };
        let id = unescape(fields[0]);
        if id.is_empty() {
            continue;
        }
        items.push(Item {
            id,
            kind: Kind::from_tag(&unescape(fields[1])),
            text: unescape(fields[2]),
            image_file: unescape(fields[3]),
            source: unescape(fields[4]),
            created_at,
            pinned: unescape(fields[6]) == "1",
            concealed: unescape(fields[7]) == "1",
            title: unescape(fields[8]),
            keyword: unescape(fields[9]),
        });
    }
    let mut store = Store::new(limit);
    store.replace_all(items);
    store
}

/// 把会撑破行式格式的字符转义掉。
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other => out.push(other),
        }
    }
    out
}

/// [`escape`] 的逆操作。认不出的转义原样留着，别把内容改坏。
fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// 关键字归一：去空白、转小写。
///
/// 用户在编辑框里手打关键字时很容易带上空格或大写，
/// 而触发时打的是另一种写法 —— 归一之后两边才对得上。
pub fn normalize_keyword(raw: &str) -> String {
    raw.trim().to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, text: &str, at: i64) -> Item {
        Item::text(id, text, at)
    }

    #[test]
    fn duplicates_refresh_the_original_instead_of_adding_a_second_copy() {
        let mut store = Store::new(10);
        store.add(item("a", "hello", 100));
        store.toggle_pin("a");

        store.add(item("b", "hello", 200));
        assert_eq!(store.items().len(), 1, "重复内容不该新增一条");
        // 关键：id 与收藏状态都保住了
        assert_eq!(store.items()[0].id, "a");
        assert!(store.items()[0].pinned, "去重不能把收藏状态弄丢");
        assert_eq!(store.items()[0].created_at, 200, "时间戳要刷新");
    }

    #[test]
    fn a_duplicate_of_a_snippet_does_not_destroy_its_title_and_keyword() {
        let mut store = Store::new(10);
        store.add_snippet("s", "签名", "此致敬礼", "sig", 100);
        // 用户又把同样的内容复制了一次
        store.add(item("x", "此致敬礼", 200));
        let snippet = &store.items()[0];
        assert_eq!(snippet.title, "签名");
        assert_eq!(snippet.keyword, "sig");
        assert!(snippet.is_snippet());
    }

    #[test]
    fn pinned_items_survive_every_kind_of_eviction() {
        let mut store = Store::new(2);
        store.add(item("keep", "收藏的", 100));
        store.toggle_pin("keep");
        for n in 0..10 {
            store.add(item(&format!("n{n}"), &format!("普通 {n}"), 200 + n));
        }
        assert!(store.items().iter().any(|e| e.id == "keep"), "超限淘汰不该动收藏");

        store.prune_expired(1, 10_000_000);
        assert!(store.items().iter().any(|e| e.id == "keep"), "过期清理不该动收藏");

        store.clear();
        assert!(store.items().iter().any(|e| e.id == "keep"), "清空不该动收藏");
        assert_eq!(store.items().len(), 1);
    }

    #[test]
    fn the_limit_counts_only_unpinned_items() {
        let mut store = Store::new(3);
        for n in 0..5 {
            store.add(item(&format!("p{n}"), &format!("收藏 {n}"), n));
            store.toggle_pin(&format!("p{n}"));
        }
        for n in 0..5 {
            store.add(item(&format!("u{n}"), &format!("普通 {n}"), 100 + n));
        }
        let unpinned = store.items().iter().filter(|e| !e.pinned).count();
        assert_eq!(unpinned, 3, "上限只管普通条目");
        assert_eq!(store.items().iter().filter(|e| e.pinned).count(), 5);
    }

    #[test]
    fn eviction_takes_the_oldest_first() {
        let mut store = Store::new(2);
        store.add(item("old", "最旧", 100));
        store.add(item("mid", "中间", 200));
        let dropped = store.add(item("new", "最新", 300));
        assert_eq!(dropped.len(), 1);
        assert_eq!(dropped[0].id, "old");
    }

    #[test]
    fn pinned_items_sort_above_everything_else() {
        let mut store = Store::new(10);
        store.add(item("a", "早的", 100));
        store.add(item("b", "晚的", 200));
        store.toggle_pin("a");
        assert_eq!(store.items()[0].id, "a", "收藏应当在最前，哪怕它更旧");
        assert_eq!(store.items()[1].id, "b");
    }

    #[test]
    fn links_are_classified_apart_from_plain_text() {
        assert_eq!(Item::text("1", "https://example.com", 0).kind, Kind::Link);
        assert_eq!(Item::text("2", "http://a.b/c?d=e", 0).kind, Kind::Link);
        // 带空格的不是链接，句子里提到网址也不该被归成链接
        assert_eq!(Item::text("3", "见 https://example.com", 0).kind, Kind::Text);
        assert_eq!(Item::text("4", "note: 见下", 0).kind, Kind::Text);
        assert_eq!(Item::text("5", "ftp://x", 0).kind, Kind::Text);
    }

    #[test]
    fn search_matches_content_and_title_case_insensitively() {
        let mut store = Store::new(10);
        store.add(item("a", "Hello World", 100));
        store.add_snippet("s", "邮箱签名", "me@example.com", "mail", 200);

        assert_eq!(store.search("hello", Filter::All).len(), 1);
        assert_eq!(store.search("HELLO", Filter::All).len(), 1);
        assert_eq!(store.search("邮箱", Filter::All).len(), 1, "标题也要能搜到");
        assert_eq!(store.search("", Filter::All).len(), 2);
        assert_eq!(store.search("不存在", Filter::All).len(), 0);
    }

    #[test]
    fn concealed_content_cannot_be_fished_out_with_search() {
        // 打码是为了别人看不到；如果还能用搜索一个个试出来，那打码就是假的
        let mut store = Store::new(10);
        let mut secret = item("s", "hunter2", 100);
        secret.concealed = true;
        secret.title = "密码管理器".into();
        store.add(secret);

        assert_eq!(store.search("hunter", Filter::All).len(), 0, "不能按内容搜到");
        assert_eq!(store.search("密码管理器", Filter::All).len(), 1, "标题仍可搜");
    }

    #[test]
    fn concealed_items_are_masked_in_the_list() {
        let mut secret = item("s", "hunter2", 0);
        secret.concealed = true;
        assert!(!secret.display_title().contains("hunter"));
    }

    #[test]
    fn filters_pick_out_the_right_subsets() {
        let mut store = Store::new(10);
        store.add(item("t", "纯文本", 100));
        store.add(item("l", "https://example.com", 200));
        store.add_snippet("s", "片段", "内容", "kw", 300);
        store.add(item("p", "被收藏的", 400));
        store.toggle_pin("p");

        // 片段的内容也是文本，所以「只看文本」会包含它 —— 类型筛选看的是
        // 内容形态，不是它有没有被收藏
        assert_eq!(store.search("", Filter::Text).len(), 3);
        assert_eq!(store.search("", Filter::Link).len(), 1);
        assert_eq!(store.search("", Filter::Pinned).len(), 2, "片段也是收藏");
        assert_eq!(store.search("", Filter::Snippet).len(), 1, "但只有一条是片段");
    }

    #[test]
    fn keywords_are_normalised_on_both_sides() {
        let mut store = Store::new(10);
        store.add_snippet("s", "签名", "内容", "  SIG  ", 100);
        assert_eq!(store.items()[0].keyword, "sig");
        assert!(store.snippet_for_keyword("SIG").is_some());
        assert!(store.snippet_for_keyword(" sig ").is_some());
        assert!(store.snippet_for_keyword("other").is_none());
        // 空关键字不该匹配到任何东西
        assert!(store.snippet_for_keyword("").is_none());
    }

    #[test]
    fn a_pinned_item_without_a_title_or_keyword_is_not_a_snippet() {
        let mut store = Store::new(10);
        store.add(item("p", "只是收藏", 100));
        store.toggle_pin("p");
        assert!(store.items()[0].pinned);
        assert!(!store.items()[0].is_snippet());
        assert!(store.snippet_keywords().is_empty());
    }

    #[test]
    fn expiry_leaves_recent_items_alone() {
        let mut store = Store::new(10);
        store.add(item("old", "旧的", 0));
        store.add(item("new", "新的", 10 * 86_400));
        let dropped = store.prune_expired(7, 10 * 86_400);
        assert_eq!(dropped.len(), 1);
        assert_eq!(dropped[0].id, "old");
        // 0 天 = 不过期
        let mut never = Store::new(10);
        never.add(item("old", "旧的", 0));
        assert!(never.prune_expired(0, 10_000_000).is_empty());
    }

    #[test]
    fn removing_concealed_items_returns_them_for_file_cleanup() {
        let mut store = Store::new(10);
        let mut secret = item("s", "密码", 100);
        secret.concealed = true;
        store.add(secret);
        store.add(item("n", "普通", 200));
        let dropped = store.remove_concealed();
        assert_eq!(dropped.len(), 1);
        assert_eq!(store.items().len(), 1);
    }

    #[test]
    fn an_index_survives_a_round_trip_with_multiline_content() {
        // 剪贴板里什么都有：多行日志、带制表符的表格、Windows 的 \r\n
        let mut store = Store::new(10);
        let mut messy = item("a", "第一行\n第二行\t带制表符\r\n还有反斜杠 \\ 与引号 \"", 100);
        messy.source = "某个\t程序".into();
        store.add(messy.clone());
        store.add_snippet("s", "标\n题", "内容", "kw", 200);

        let restored = decode_index(&encode_index(&store), 10);
        assert_eq!(restored.items().len(), 2);
        let back = restored.items().iter().find(|e| e.id == "a").unwrap();
        assert_eq!(back.text, messy.text, "内容必须一字不差地回来");
        assert_eq!(back.source, "某个\t程序");
        let snippet = restored.items().iter().find(|e| e.id == "s").unwrap();
        assert_eq!(snippet.title, "标\n题");
        assert!(snippet.is_snippet(), "片段的身份也要跟着回来");
    }

    #[test]
    fn every_record_occupies_exactly_one_line() {
        // 一条记录跨行的话，下次读回来就切错了
        let mut store = Store::new(10);
        store.add(item("a", "多\n行\n内\n容", 100));
        store.add(item("b", "另一条", 200));
        assert_eq!(encode_index(&store).lines().count(), 2);
    }

    #[test]
    fn a_corrupt_line_costs_one_record_not_the_whole_history() {
        let mut store = Store::new(10);
        store.add(item("a", "好的", 100));
        store.add(item("b", "也好的", 200));
        let mut text = encode_index(&store);
        text.push_str("这一行是垃圾\n");
        text.push_str("字段不够\t也不行\n");

        let restored = decode_index(&text, 10);
        assert_eq!(restored.items().len(), 2, "坏行跳过，好行照读");
    }

    #[test]
    fn decoding_still_honours_the_limit_and_keeps_pinned_items() {
        let mut store = Store::new(100);
        store.add(item("keep", "收藏", 0));
        store.toggle_pin("keep");
        for n in 0..10 {
            store.add(item(&format!("n{n}"), &format!("{n}"), 100 + n));
        }
        let restored = decode_index(&encode_index(&store), 2);
        assert!(restored.items().iter().any(|e| e.id == "keep"));
        assert_eq!(restored.items().iter().filter(|e| !e.pinned).count(), 2);
    }

    #[test]
    fn unknown_type_tags_degrade_to_text_instead_of_dropping_the_record() {
        // 老版本读到新版本写的类型时，降级显示总比丢记录好
        assert_eq!(Kind::from_tag("未来类型"), Kind::Text);
        assert_eq!(Kind::from_tag("image"), Kind::Image);
        assert_eq!(Kind::from_tag(Kind::File.tag()), Kind::File);
    }
}
