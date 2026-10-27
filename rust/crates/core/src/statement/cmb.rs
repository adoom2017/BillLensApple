//! 招商银行信用卡电子账单的行文本解析。
//!
//! 输入是 `source` 规范化后的行（HTML 每个表格行一行；PDF 为 PDFKit 的行，长摘要会折行，
//! 偶尔把摘要片段、`CN`、`_` 挪到相邻行）。交易行以尾部
//! `¥ 金额 卡号末四位 [地点] 交易地金额` 为锚点切分，头部取 1–2 个 `MMDD` 日期，
//! 其余文字拼成摘要，因此折行不影响金额、日期与行序。

use anyhow::{Result, anyhow, bail};
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatementSection {
    Repayment,
    Installment,
    Refund,
    Purchase,
    Cash,
    Fee,
    Interest,
    Other,
}

impl StatementSection {
    fn from_header(line: &str) -> Option<Self> {
        Some(match line {
            "还款" => Self::Repayment,
            "分期" => Self::Installment,
            "退款" => Self::Refund,
            "消费" => Self::Purchase,
            "取现" => Self::Cash,
            "费用" => Self::Fee,
            "利息" => Self::Interest,
            "其他" | "调整" => Self::Other,
            _ => return None,
        })
    }

    fn title(&self) -> &'static str {
        match self {
            Self::Repayment => "还款",
            Self::Installment => "分期",
            Self::Refund => "退款",
            Self::Purchase => "消费",
            Self::Cash => "取现",
            Self::Fee => "费用",
            Self::Interest => "利息",
            Self::Other => "其他",
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Repayment => "repayment",
            Self::Installment => "installment",
            Self::Refund => "refund",
            Self::Purchase => "purchase",
            Self::Cash => "cash",
            Self::Fee => "fee",
            Self::Interest => "interest",
            Self::Other => "other",
        }
    }
}

/// 账单汇总，金额单位为分。顺序与招行账单汇总栏一致。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CmbSummary {
    pub amount_due: i64,
    pub previous_balance: i64,
    pub previous_payment: i64,
    pub new_charges: i64,
    pub adjustment: i64,
    pub interest: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CmbRow {
    pub section: StatementSection,
    pub transaction_on: Option<NaiveDate>,
    pub posted_on: NaiveDate,
    pub description: String,
    /// 人民币入账金额（分），保留账单符号：退款、还款为负。
    pub amount_cents: i64,
    pub card_last4: String,
    pub location: Option<String>,
    /// 交易地金额（分），境外交易为原币金额。
    pub settlement_cents: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CmbStatement {
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub due_on: Option<NaiveDate>,
    pub summary: Option<CmbSummary>,
    pub rows: Vec<CmbRow>,
}

pub(crate) fn parse(lines: &[String]) -> Result<CmbStatement> {
    let (period_index, period_start, period_end) = lines
        .iter()
        .enumerate()
        .find_map(|(i, line)| parse_period(line).map(|(start, end)| (i, start, end)))
        .ok_or_else(|| anyhow!("未找到账单周期，这可能不是招商银行信用卡电子账单"))?;

    let mut due_on = None;
    let mut summary = None;
    let mut sections: Vec<(StatementSection, Vec<&str>)> = Vec::new();
    for line in &lines[period_index + 1..] {
        if !sections.is_empty() {
            if line.starts_with('★') {
                break;
            }
            if let Some(section) = StatementSection::from_header(line) {
                sections.push((section, Vec::new()));
            } else if let Some((_, body)) = sections.last_mut() {
                body.push(line);
            }
            continue;
        }
        if let Some(section) = StatementSection::from_header(line) {
            sections.push((section, Vec::new()));
        } else if due_on.is_none() && summary.is_none() {
            // 到期还款日是汇总栏之前单独一行的完整日期。
            due_on = parse_full_date(line);
        }
        if summary.is_none() {
            summary = parse_summary(line);
        }
    }

    if sections.is_empty() {
        bail!("账单中没有交易明细，可能是不含明细的电邮对账通知");
    }

    let mut rows = Vec::new();
    for (section, body) in sections {
        rows.extend(parse_section_rows(&section, &body, period_end)?);
    }
    if rows.is_empty() {
        bail!("账单中未识别到任何交易");
    }

    Ok(CmbStatement {
        period_start,
        period_end,
        due_on,
        summary,
        rows,
    })
}

struct Token<'a> {
    text: &'a str,
    line: usize,
}

fn parse_section_rows(
    section: &StatementSection,
    body: &[&str],
    period_end: NaiveDate,
) -> Result<Vec<CmbRow>> {
    let tokens: Vec<Token> = body
        .iter()
        .enumerate()
        .flat_map(|(line, text)| text.split(' ').map(move |text| Token { text, line }))
        .collect();

    let mut rows = Vec::new();
    let mut head_start = 0;
    let mut i = 0;
    while i < tokens.len() {
        let Some((amount_cents, tail_len, card_last4, location, settlement_cents)) =
            match_tail(&tokens[i..])
        else {
            i += 1;
            continue;
        };
        let head = &tokens[head_start..i];
        rows.push(build_row(
            section,
            head,
            amount_cents,
            card_last4,
            location,
            settlement_cents,
            period_end,
        )?);
        i += tail_len;
        head_start = i;
    }

    let leftover = &tokens[head_start..];
    if leftover.iter().any(|token| !is_stray_token(token.text)) {
        // 错误会进入 App 日志，只报告位置，不带摘要、金额等账单内容。
        bail!(
            "无法解析「{}」分区第 {} 笔之后的交易行",
            section.title(),
            rows.len()
        );
    }
    Ok(rows)
}

/// `¥ 金额 末四位 [地点] 交易地金额`，`¥` 也可能与金额连写。
fn match_tail(tokens: &[Token]) -> Option<(i64, usize, String, Option<String>, i64)> {
    let first = tokens.first()?.text;
    let (amount, mut next) = if first == "¥" {
        (parse_cents(tokens.get(1)?.text)?, 2)
    } else {
        (parse_cents(first.strip_prefix('¥')?)?, 1)
    };
    let card = tokens.get(next)?.text;
    if !(card.len() == 4 && card.chars().all(|c| c.is_ascii_digit())) {
        return None;
    }
    next += 1;
    let mut location = None;
    if let Some(token) = tokens.get(next)
        && is_location_code(token.text)
    {
        location = Some(token.text.to_string());
        next += 1;
    }
    let settlement = parse_cents(tokens.get(next)?.text)?;
    Some((amount, next + 1, card.to_string(), location, settlement))
}

fn build_row(
    section: &StatementSection,
    head: &[Token],
    amount_cents: i64,
    card_last4: String,
    location: Option<String>,
    settlement_cents: i64,
    period_end: NaiveDate,
) -> Result<CmbRow> {
    let date_index = head
        .iter()
        .position(|token| parse_mmdd(token.text).is_some())
        .ok_or_else(|| anyhow!("「{}」分区有交易行缺少日期", section.title()))?;
    let second_is_date = head
        .get(date_index + 1)
        .is_some_and(|token| parse_mmdd(token.text).is_some());
    let first = resolve_year(parse_mmdd(head[date_index].text).unwrap(), period_end)?;
    let (transaction_on, posted_on, desc_start) = if second_is_date {
        let posted = resolve_year(parse_mmdd(head[date_index + 1].text).unwrap(), period_end)?;
        (Some(first), posted, date_index + 2)
    } else {
        (None, first, date_index + 1)
    };

    // 日期之前的片段是 PDF 折行把摘要开头放在了日期上方；孤立的 `CN`、`_` 属于上一行。
    let prefix: Vec<&Token> = head[..date_index]
        .iter()
        .filter(|token| !is_stray_token(token.text))
        .collect();
    let suffix: Vec<&Token> = head[desc_start..].iter().collect();
    let description = join_tokens_refs(prefix.into_iter().chain(suffix));
    if description.is_empty() {
        bail!("账单交易行缺少摘要");
    }

    Ok(CmbRow {
        section: section.clone(),
        transaction_on,
        posted_on,
        description,
        amount_cents,
        card_last4,
        location,
        settlement_cents,
    })
}

/// 同一原始行内的词以空格连接；跨行（PDF 折行）的片段直接拼接。
fn join_tokens_refs<'a, 'b: 'a>(tokens: impl Iterator<Item = &'a Token<'b>>) -> String {
    let mut text = String::new();
    let mut last_line = None;
    for token in tokens {
        if let Some(line) = last_line
            && line == token.line
        {
            text.push(' ');
        }
        text.push_str(token.text);
        last_line = Some(token.line);
    }
    text
}

fn is_stray_token(text: &str) -> bool {
    is_location_code(text) || text.chars().all(|c| !c.is_alphanumeric())
}

fn is_location_code(text: &str) -> bool {
    text.len() == 2 && text.chars().all(|c| c.is_ascii_uppercase())
}

fn parse_mmdd(text: &str) -> Option<(u32, u32)> {
    if text.len() != 4 || !text.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let month: u32 = text[..2].parse().ok()?;
    let day: u32 = text[2..].parse().ok()?;
    ((1..=12).contains(&month) && (1..=31).contains(&day)).then_some((month, day))
}

/// 先取账期结束年；晚于账期结束则为上一年（跨年账期、早于账期的分期原始交易日）。
fn resolve_year((month, day): (u32, u32), period_end: NaiveDate) -> Result<NaiveDate> {
    use chrono::Datelike;
    let year = period_end.year();
    NaiveDate::from_ymd_opt(year, month, day)
        .filter(|date| *date <= period_end)
        .or_else(|| NaiveDate::from_ymd_opt(year - 1, month, day))
        .ok_or_else(|| anyhow!("无效的账单日期 {month:02}{day:02}"))
}

fn parse_period(line: &str) -> Option<(NaiveDate, NaiveDate)> {
    line.split(' ').find_map(|token| {
        let (start, end) = token.split_once('-')?;
        Some((parse_full_date(start)?, parse_full_date(end)?))
    })
}

fn parse_full_date(text: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(text, "%Y/%m/%d").ok()
}

/// 汇总栏是同一行里恰好 6 个 `¥` 金额。
fn parse_summary(line: &str) -> Option<CmbSummary> {
    let parts: Vec<&str> = line.split('¥').map(str::trim).collect();
    if parts.len() != 7 || !parts[0].is_empty() {
        return None;
    }
    let values: Vec<i64> = parts[1..]
        .iter()
        .map(|part| parse_cents(part))
        .collect::<Option<_>>()?;
    Some(CmbSummary {
        amount_due: values[0],
        previous_balance: values[1],
        previous_payment: values[2],
        new_charges: values[3],
        adjustment: values[4],
        interest: values[5],
    })
}

/// `-12,744.44` → -1274444。必须恰好两位小数，避免把日期、卡号当成金额。
pub(crate) fn parse_cents(text: &str) -> Option<i64> {
    let (negative, digits) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    let (integer, fraction) = digits.split_once('.')?;
    if fraction.len() != 2
        || !fraction.chars().all(|c| c.is_ascii_digit())
        || integer.is_empty()
        || !integer.chars().all(|c| c.is_ascii_digit() || c == ',')
    {
        return None;
    }
    let integer: i64 = integer.replace(',', "").parse().ok()?;
    let cents = integer
        .checked_mul(100)?
        .checked_add(fraction.parse().ok()?)?;
    Some(if negative { -cents } else { cents })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Vec<String> {
        crate::statement::source::text_to_lines(text)
    }

    fn date(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    #[test]
    fn parses_header_summary_and_every_row_shape() {
        let statement = parse(&lines(
            "尊敬的 客户\n2026/09/26-2026/10/25 ¥ 50,000.00\n¥ 100.00 ¥ 10.00\n2026/11/13\n\
             ¥ 100.00 ¥ 200.00 ¥ 200.00 ¥ 100.20 ¥ 0.20 ¥ 0.00\n\
             还款\n1013 自动还款 ¥ -200.00 0000 -200.00\n\
             分期\n0412 1013 消费分期-苹果在线商店 本金 第7/24期 ¥ 50.00 0000 50.00\n\
             退款\n1009 1010 支付宝-盒马 ¥ -0.20 0000 CN -0.20\n\
             消费\n0926 0927 财付通-瑞幸咖啡 ¥ 50.20 0000 CN 50.20\n★说明",
        ))
        .unwrap();
        assert_eq!(statement.period_start, date(2026, 9, 26));
        assert_eq!(statement.period_end, date(2026, 10, 25));
        assert_eq!(statement.due_on, Some(date(2026, 11, 13)));
        assert_eq!(statement.summary.unwrap().new_charges, 10020);
        let rows = &statement.rows;
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].section, StatementSection::Repayment);
        assert_eq!(rows[0].transaction_on, None);
        assert_eq!(rows[0].posted_on, date(2026, 10, 13));
        assert_eq!(rows[0].amount_cents, -20000);
        assert_eq!(rows[1].transaction_on, Some(date(2026, 4, 12)));
        assert_eq!(rows[1].description, "消费分期-苹果在线商店 本金 第7/24期");
        assert_eq!(rows[2].location.as_deref(), Some("CN"));
        assert_eq!(rows[3].description, "财付通-瑞幸咖啡");
    }

    #[test]
    fn pdf_wrapped_rows_keep_amounts_dates_and_order() {
        let statement = parse(&lines(
            "2026/09/26-2026/10/25 ¥ 1.00\n消费\n\
             0927 0928 美团支付-美团北京三快在线科技有限公\n司 ¥ 93.30 0000 CN 93.30\n\
             0930 1001 支付宝-煮物\n创造美食 ¥ 43.00 0000 CN 43.00\n_\n\
             1001 1002 拼多多支付-桌搭 ¥ 34.77 0000 CN 34.77\n\
             美团支付-美团嫩牛五方（西兴\n1015 1016 店） ¥ 20.56 0000 CN 20.56\n\
             1022 1023 财付通-瑞幸 ¥ 9.90 0000 9.90\nCN\n\
             1023 1024 支付宝-度友 ¥ 175.32 0000 CN 175.32\n★",
        ))
        .unwrap();
        let descriptions: Vec<_> = statement
            .rows
            .iter()
            .map(|r| r.description.as_str())
            .collect();
        assert_eq!(
            descriptions,
            vec![
                "美团支付-美团北京三快在线科技有限公司",
                "支付宝-煮物创造美食",
                "拼多多支付-桌搭",
                // NFKC 把全角括号规范为半角，HTML 与 PDF 来源一致。
                "美团支付-美团嫩牛五方(西兴店)",
                "财付通-瑞幸",
                "支付宝-度友",
            ]
        );
        assert_eq!(statement.rows[4].location, None);
        assert_eq!(statement.rows[3].amount_cents, 2056);
    }

    #[test]
    fn cross_year_period_resolves_december_to_previous_year() {
        let statement = parse(&lines(
            "2026/12/26-2027/01/25\n消费\n1228 1229 商户 ¥ 1.00 0000 CN 1.00\n\
             0105 0106 商户 ¥ 2.00 0000 CN 2.00",
        ))
        .unwrap();
        assert_eq!(statement.rows[0].transaction_on, Some(date(2026, 12, 28)));
        assert_eq!(statement.rows[1].transaction_on, Some(date(2027, 1, 5)));
    }

    #[test]
    fn missing_period_or_sections_or_garbage_rows_fail_loudly() {
        assert!(parse(&lines("消费\n0926 0927 商户 ¥ 1.00 0000 CN 1.00")).is_err());
        let error = parse(&lines("2026/09/26-2026/10/25\n本期应还 ¥ 1.00")).unwrap_err();
        assert!(error.to_string().contains("不含明细"));
        // 错误信息会写入日志，不得包含摘要或金额。
        for garbage in [
            "2026/09/26-2026/10/25\n消费\n0926 0927 商户 ¥ 1.00 0000 CN",
            "2026/09/26-2026/10/25\n消费\n商户 ¥ 1.00 0000 CN 1.00",
        ] {
            let message = parse(&lines(garbage)).unwrap_err().to_string();
            assert!(message.contains("消费"), "{message}");
            assert!(
                !message.contains("商户") && !message.contains("1.00"),
                "{message}"
            );
        }
    }

    #[test]
    fn cents_parsing_requires_two_decimals() {
        assert_eq!(parse_cents("-12,744.44"), Some(-1_274_444));
        assert_eq!(parse_cents("0.06"), Some(6));
        assert_eq!(parse_cents("2034"), None);
        assert_eq!(parse_cents("1.5"), None);
        assert_eq!(parse_cents(".50"), None);
    }
}
