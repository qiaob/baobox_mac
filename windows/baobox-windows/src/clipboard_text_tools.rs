use baobox_core::textformat::{self, Match};
use sha2::{Digest, Sha256};

#[derive(Clone, Copy)]
pub struct Action {
    pub id: &'static str,
    pub title: &'static str,
}

const fn action(id: &'static str, title: &'static str) -> Action {
    Action { id, title }
}

pub const ENCODING: &[Action] = &[
    action("base64.encode", "Base64 编码"),
    action("base64.decode", "Base64 解码"),
    action("jwt.decode", "JWT 解码"),
    action("md5", "MD5"),
    action("sha1", "SHA-1"),
    action("sha256", "SHA-256"),
];

pub const COMMON: &[Action] = &[
    action("qr", "二维码"),
    action("pin", "钉住"),
    action("edit", "编辑"),
];

pub fn format_actions(found: &Match) -> &'static [Action] {
    match (found.id, found.badge.as_str()) {
        ("json", _) => {
            const {
                &[
                    action("json.pretty", "格式化"),
                    action("json.minify", "压缩"),
                    action("json.escape", "转义"),
                    action("json.unescape", "反转义"),
                ]
            }
        }
        ("xml", _) => const { &[action("xml.pretty", "格式化"), action("xml.minify", "压缩")] },
        ("url", "cURL") => {
            const {
                &[
                    action("curl.format", "格式化"),
                    action("curl.minify", "压成一行"),
                    action("curl.url", "提取 URL"),
                ]
            }
        }
        ("url", _) => {
            const {
                &[
                    action("url.decode", "URL 解码"),
                    action("url.encode", "URL 编码"),
                    action("url.curl", "转为 cURL"),
                ]
            }
        }
        ("jwt", _) => {
            const {
                &[
                    action("jwt.payload", "提取 Payload"),
                    action("jwt.header", "提取 Header"),
                ]
            }
        }
        ("base64", _) => const { &[action("base64.decode", "解码")] },
        _ => &[],
    }
}

pub fn detect(text: &str) -> Vec<Match> {
    let text = text.trim();
    let mut formats = textformat::detect(text);
    formats.retain(|item| !matches!(item.id, "common" | "xml"));
    if text.len() <= textformat::MAX_LENGTH && text.starts_with('<') && xml(text).is_some() {
        formats.push(Match {
            id: "xml",
            badge: "XML".into(),
            rendered: None,
            rows: Vec::new(),
            actions: Vec::new(),
        });
    }
    for item in &mut formats {
        match item.id {
            "json" => item.rows.clear(),
            "url" => {
                item.rows = text
                    .split_once('?')
                    .map(|(_, query)| query.split('#').next().unwrap_or_default())
                    .into_iter()
                    .flat_map(|query| query.split('&').filter(|pair| !pair.is_empty()))
                    .map(|pair| {
                        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
                        row(
                            &textformat::apply("url.decode", key).unwrap_or_else(|| key.into()),
                            textformat::apply("url.decode", value).unwrap_or_else(|| value.into()),
                        )
                    })
                    .collect();
            }
            _ => {}
        }
    }
    if text.len() <= textformat::MAX_LENGTH {
        if let Some(tokens) = curl_tokens(text) {
            let url = curl_url(&tokens).unwrap_or_default();
            let value = |keys: &'static [&'static str]| {
                tokens
                    .windows(2)
                    .filter(move |pair| keys.contains(&pair[0].as_str()))
                    .map(|pair| pair[1].clone())
            };
            let body: Vec<_> = value(&[
                "-d",
                "--data",
                "--data-raw",
                "--data-binary",
                "--data-urlencode",
            ])
            .collect();
            let method = value(&["-X", "--request"]).next().unwrap_or_else(|| {
                if body.is_empty() && value(&["-F", "--form"]).next().is_none() {
                    "GET"
                } else {
                    "POST"
                }
                .into()
            });
            let mut rows = vec![row("方法", method), row("URL", url.to_owned())];
            rows.extend(value(&["-H", "--header"]).map(|header| {
                let (name, value) = header.split_once(':').unwrap_or((&header, ""));
                row(name, value.trim().to_owned())
            }));
            if !body.is_empty() {
                rows.push(row("请求体", body.join("&")));
            }
            formats.push(Match {
                id: "url",
                badge: "cURL".into(),
                rendered: None,
                rows,
                actions: Vec::new(),
            });
        } else if !formats.iter().any(|item| item.id == "json")
            && json_unescape(text)
                .is_some_and(|plain| textformat::apply("json.pretty", &plain).is_some())
        {
            formats.push(Match {
                id: "json",
                badge: "JSON".into(),
                rendered: None,
                rows: Vec::new(),
                actions: Vec::new(),
            });
        }
    }
    formats.sort_by_key(|item| match item.id {
        "jwt" => 0,
        "json" => 1,
        "xml" => 2,
        "timestamp" => 3,
        "url" => 4,
        _ => 5,
    });
    formats
}

fn row(label: &str, value: String) -> textformat::Row {
    textformat::Row {
        label: label.into(),
        value,
        warning: false,
    }
}

pub fn transform(id: &str, text: &str) -> Option<String> {
    let text = text.trim();
    if text.len() > textformat::MAX_LENGTH
        && matches!(
            id,
            "json.pretty" | "json.minify" | "json.unescape" | "xml.pretty" | "xml.minify"
        )
    {
        return None;
    }
    match id {
        "json.escape" => serde_json::to_string(text).ok(),
        "json.unescape" => json_unescape(text),
        "xml.pretty" | "xml.minify" => {
            let mut output = Vec::new();
            xml(text)?
                .write_with_config(
                    &mut output,
                    xmltree::EmitterConfig::new().perform_indent(id == "xml.pretty"),
                )
                .ok()?;
            String::from_utf8(output).ok()
        }
        "jwt.decode" => Some(format!(
            "{}\n\n{}",
            textformat::apply("jwt.header", text)?,
            textformat::apply("jwt.payload", text)?
        )),
        "md5" => digest(
            text,
            windows::Win32::Security::Cryptography::BCRYPT_MD5_ALG_HANDLE,
            16,
        ),
        "sha1" => digest(
            text,
            windows::Win32::Security::Cryptography::BCRYPT_SHA1_ALG_HANDLE,
            20,
        ),
        "sha256" => Some(format!("{:x}", Sha256::digest(text.as_bytes()))),
        "url.curl" => Some(format!("curl {}", quote(text))),
        "url.encode" => {
            let mut encoded = String::new();
            for byte in text.bytes() {
                use std::fmt::Write;
                if byte.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@/?".contains(&byte) {
                    encoded.push(byte as char);
                } else {
                    let _ = write!(encoded, "%{byte:02X}");
                }
            }
            Some(encoded)
        }
        "curl.url" => curl_url(&curl_tokens(text)?).map(str::to_owned),
        "curl.format" | "curl.minify" => {
            let tokens = curl_tokens(text)?;
            let mut groups = Vec::new();
            let mut args = tokens.into_iter().peekable();
            while let Some(token) = args.next() {
                let mut group = quote(&token);
                if token.starts_with('-') && args.peek().is_some_and(|next| !next.starts_with('-'))
                {
                    group.push(' ');
                    group.push_str(&quote(&args.next()?));
                }
                groups.push(group);
            }
            let separator = if id == "curl.format" {
                concat!(" ", "\\", "\n  ")
            } else {
                " "
            };
            Some(groups.join(separator))
        }
        _ => textformat::apply(id, text),
    }
}

fn xml(text: &str) -> Option<xmltree::Element> {
    if text.contains("<!DOCTYPE") {
        return None;
    }
    // xmltree builds and writes the element tree recursively. Reject deep
    // clipboard input with the streaming reader before building that tree.
    let mut depth = 0;
    for event in xml::reader::EventReader::from_str(text) {
        match event.ok()? {
            xml::reader::XmlEvent::StartElement { .. } => {
                depth += 1;
                if depth > 128 {
                    return None;
                }
            }
            xml::reader::XmlEvent::EndElement { .. } => depth -= 1,
            _ => {}
        }
    }
    xmltree::Element::parse(text.as_bytes()).ok()
}

fn json_unescape(text: &str) -> Option<String> {
    let mut text = text.to_owned();
    let mut peeled = false;
    for _ in 0..3 {
        let Ok(inner) = serde_json::from_str::<String>(text.trim()) else {
            break;
        };
        peeled = true;
        text = inner;
    }
    peeled.then(|| textformat::apply("json.pretty", &text).unwrap_or(text))
}

fn digest(
    text: &str,
    algorithm: windows::Win32::Security::Cryptography::BCRYPT_ALG_HANDLE,
    len: usize,
) -> Option<String> {
    let mut bytes = vec![0; len];
    let status = unsafe {
        windows::Win32::Security::Cryptography::BCryptHash(
            algorithm,
            None,
            text.as_bytes(),
            &mut bytes,
        )
    };
    (status.0 >= 0).then(|| bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn curl_url(tokens: &[String]) -> Option<&str> {
    tokens
        .windows(2)
        .find(|pair| pair[0] == "--url")
        .map(|pair| pair[1].as_str())
        .or_else(|| {
            tokens
                .iter()
                .skip(1)
                .find(|token| token.starts_with("https://") || token.starts_with("http://"))
                .map(String::as_str)
        })
}

fn curl_tokens(text: &str) -> Option<Vec<String>> {
    if text.len() > 64 * 1024 || !text.starts_with("curl ") {
        return None;
    }
    let mut chars = text.chars().peekable();
    let mut tokens = Vec::new();
    while chars.peek().is_some() {
        if chars.next_if(|c| c.is_whitespace()).is_some() {
            continue;
        }
        let mut token = String::new();
        let mut quoted = None;
        let mut started = false;
        while let Some(c) = chars.next() {
            match c {
                c if c.is_whitespace() && quoted.is_none() => break,
                '\'' | '"' if quoted == Some(c) => quoted = None,
                '\'' | '"' if quoted.is_none() => {
                    quoted = Some(c);
                    started = true;
                }
                '\\' if quoted != Some('\'') => {
                    let next = chars.next()?;
                    if next == '\r' {
                        chars.next_if_eq(&'\n');
                    } else if next != '\n' {
                        token.push(next);
                        started = true;
                    }
                }
                _ => {
                    token.push(c);
                    started = true;
                }
            }
        }
        if quoted.is_some() {
            return None;
        }
        if started {
            tokens.push(token);
        }
    }
    curl_url(&tokens)?;
    Some(tokens)
}

fn quote(text: &str) -> String {
    if !text.is_empty()
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_./:".contains(&byte))
    {
        text.into()
    } else {
        format!("'{}'", text.replace('\'', "'\\''"))
    }
}

pub fn qr(text: &str) -> Option<(u32, u32, Vec<u8>)> {
    let code = qrcode::QrCode::new(text.as_bytes()).ok()?;
    let modules = code.width();
    let scale = 1024 / (modules + 8);
    let side = (modules + 8) * scale;
    let mut pixels = vec![255; side * side * 4];
    for y in 0..modules {
        for x in 0..modules {
            if code[(x, y)] != qrcode::Color::Dark {
                continue;
            }
            for row in (y + 4) * scale..(y + 5) * scale {
                for col in (x + 4) * scale..(x + 5) * scale {
                    pixels[(row * side + col) * 4..][..3].fill(0);
                }
            }
        }
    }
    Some((side as u32, side as u32, pixels))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xml_tools_require_valid_bounded_xml_without_external_entities() {
        assert_eq!(detect("<a/>")[0].badge, "XML");
        assert!(transform("xml.pretty", "<a><b>text</b></a>")
            .unwrap()
            .contains("<b>text</b>"));
        assert!(transform("xml.pretty", "<a></b>").is_none());
        assert!(transform("xml.pretty", "<!DOCTYPE a SYSTEM \"file:///secret\"><a/>").is_none());
        let deep = "<a>".repeat(129) + &"</a>".repeat(129);
        assert!(transform("xml.pretty", &deep).is_none());
    }

    #[test]
    fn curl_tools_preserve_quoted_arguments_when_reformatting() {
        let original = r#"curl 'https://example.test/?q=a&b=c' -H 'X-Test: A B' -d '{"x":1}'"#;
        let formatted = transform("curl.format", original).unwrap();
        assert_eq!(curl_tokens(original), curl_tokens(&formatted));
        assert_eq!(
            transform("curl.url", &formatted).as_deref(),
            Some("https://example.test/?q=a&b=c")
        );
    }
}
