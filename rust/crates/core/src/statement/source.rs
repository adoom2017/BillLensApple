//! 账单来源解码：`.eml` → HTML，HTML / PDF 文字 → 规范化的行文本。
//!
//! HTML 与 PDF 最终都变成「一行一个逻辑行」的文本，交给同一个银行解析器，
//! 保证两种来源得到相同的交易行与确定性 ID。

use anyhow::{Context, Result, anyhow};
use base64::Engine;
use mail_parser::MessageParser;
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatementSourceKind {
    /// 原始 `.eml` 字节的 base64（字符集不一定是 UTF-8）。
    Eml,
    /// 邮件 HTML 正文。
    Html,
    /// PDFKit 提取的整份 PDF 文字（iOS Mail 打印生成）。
    PdfText,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatementSourceInput {
    pub kind: StatementSourceKind,
    pub content: String,
}

pub(crate) struct DecodedSource {
    pub sender: Option<String>,
    pub subject: Option<String>,
    pub lines: Vec<String>,
}

pub(crate) fn decode(input: &StatementSourceInput) -> Result<DecodedSource> {
    match input.kind {
        StatementSourceKind::Eml => {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(input.content.trim())
                .context("eml content must be base64")?;
            let message = MessageParser::default()
                .parse(&bytes)
                .ok_or_else(|| anyhow!("无法解析邮件文件"))?;
            let sender = message
                .from()
                .and_then(|from| from.first())
                .and_then(|addr| addr.address())
                .map(str::to_string);
            let subject = message.subject().map(str::to_string);
            let html = message
                .body_html(0)
                .ok_or_else(|| anyhow!("邮件中没有 HTML 正文"))?;
            Ok(DecodedSource {
                sender,
                subject,
                lines: html_to_lines(&html),
            })
        }
        StatementSourceKind::Html => Ok(DecodedSource {
            sender: None,
            subject: None,
            lines: html_to_lines(&input.content),
        }),
        StatementSourceKind::PdfText => Ok(DecodedSource {
            sender: None,
            subject: None,
            lines: text_to_lines(&input.content),
        }),
    }
}

/// 行边界只取 `</tr>` 与 `<br>`；同一行内的单元格以空格分隔。
pub(crate) fn html_to_lines(html: &str) -> Vec<String> {
    let html = strip_element(&strip_element(html, "script"), "style");
    let mut text = String::with_capacity(html.len() / 4);
    let mut rest = html.as_str();
    while let Some(start) = rest.find('<') {
        text.push_str(&rest[..start]);
        let Some(end) = rest[start..].find('>') else {
            rest = "";
            break;
        };
        let tag = rest[start + 1..start + end].trim().to_ascii_lowercase();
        let name: String = tag
            .trim_start_matches('/')
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        match name.as_str() {
            "br" => text.push('\n'),
            "tr" if tag.starts_with('/') => text.push('\n'),
            "td" | "th" => text.push(' '),
            _ => {}
        }
        rest = &rest[start + end + 1..];
    }
    text.push_str(rest);
    text_to_lines(&decode_entities(&text))
}

pub(crate) fn text_to_lines(text: &str) -> Vec<String> {
    text.lines()
        .map(normalize_line)
        .filter(|line| !line.is_empty())
        .collect()
}

/// NFKC 处理康熙部首（如 `⽀` → `支`），再映射 NFKC 不覆盖的 CJK 部首补充字符
/// （如 `⻢` → `马`），最后折叠空白。PDF 文字提取常见这两类字符。
fn normalize_line(line: &str) -> String {
    let normalized: String = line.nfkc().map(map_radical_supplement).collect();
    normalized.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn map_radical_supplement(c: char) -> char {
    match c {
        '⺠' => '民',
        '⻄' => '西',
        '⻅' => '见',
        '⻆' => '角',
        '⻉' => '贝',
        '⻋' => '车',
        '⻓' => '长',
        '⻔' => '门',
        '⻘' => '青',
        '⻚' => '页',
        '⻛' => '风',
        '⻜' => '飞',
        '⻝' => '食',
        '⻢' => '马',
        '⻥' => '鱼',
        '⻦' => '鸟',
        '⻨' => '麦',
        '⻩' => '黄',
        '⻬' => '齐',
        '⻮' => '齿',
        '⻰' => '龙',
        '⻳' => '龟',
        other => other,
    }
}

fn strip_element(html: &str, name: &str) -> String {
    let lower = html.to_ascii_lowercase();
    let open = format!("<{name}");
    let close = format!("</{name}>");
    let mut result = String::with_capacity(html.len());
    let mut cursor = 0;
    while let Some(start) = lower[cursor..].find(&open).map(|i| cursor + i) {
        result.push_str(&html[cursor..start]);
        match lower[start..].find(&close) {
            Some(end) => cursor = start + end + close.len(),
            None => {
                cursor = html.len();
                break;
            }
        }
    }
    result.push_str(&html[cursor..]);
    result
}

fn decode_entities(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find('&') {
        result.push_str(&rest[..start]);
        let tail = &rest[start..];
        let decoded = tail.find(';').filter(|end| *end <= 10).and_then(|end| {
            let entity = &tail[1..end];
            let c = match entity {
                "nbsp" => Some(' '),
                "yen" => Some('¥'),
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "bull" => Some('•'),
                _ => entity
                    .strip_prefix("#x")
                    .or_else(|| entity.strip_prefix("#X"))
                    .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                    .or_else(|| entity.strip_prefix('#').and_then(|dec| dec.parse().ok()))
                    .and_then(char::from_u32),
            };
            c.map(|c| (c, end))
        });
        match decoded {
            Some((c, end)) => {
                result.push(c);
                rest = &tail[end + 1..];
            }
            None => {
                result.push('&');
                rest = &tail[1..];
            }
        }
    }
    result.push_str(rest);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_rows_become_lines_with_space_separated_cells() {
        let html = "<script>var a = '<tr>';</script><TABLE><TR><TD><DIV><FONT>0926</FONT></DIV></TD>\
            <TD>支付宝-盒马</TD><TD>&yen;&nbsp;148.40</TD></TR><TR><TD>消费</TD></TR></TABLE>";
        assert_eq!(
            html_to_lines(html),
            vec!["0926 支付宝-盒马 ¥ 148.40", "消费"]
        );
    }

    #[test]
    fn pdf_radicals_are_normalized_to_unified_ideographs() {
        assert_eq!(
            text_to_lines("⽀付宝-上海盒⻢⽹络  ⻝品\n\n"),
            vec!["支付宝-上海盒马网络 食品"]
        );
    }

    #[test]
    fn numeric_entities_decode_and_unknown_ampersands_survive() {
        assert_eq!(
            decode_entities("A&#20013;&#x6587; & B&unknown;"),
            "A中文 & B&unknown;"
        );
    }
}
