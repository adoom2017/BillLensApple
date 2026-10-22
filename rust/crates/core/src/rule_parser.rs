//! 口语记账的确定性解析：金额、币种、收支方向、分类、订阅周期与时间。
//!
//! 规则能完整确定单笔账单时直接生成结果，不调用模型；否则把已确定的字段交给模型补全，
//! 模型返回后这些字段以规则结果为准。时间换算只在这里做，模型只摘录原文时间片段。

use anyhow::{Result, anyhow};
use billlens_apple_db::{ParsedRecordPayload, RecordDirection, SubscriptionCycle};
use chrono::{DateTime, Datelike, Duration, FixedOffset, NaiveDate, NaiveTime, TimeZone, Utc};

/// 规则已确定、模型不得改动的字段。
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct RuleHints {
    pub amount: Option<f64>,
    pub currency: Option<&'static str>,
    pub direction: Option<RecordDirection>,
    pub category: Option<&'static str>,
    pub merchant: Option<&'static str>,
    pub transaction_at: Option<DateTime<FixedOffset>>,
    pub subscription_cycle: Option<SubscriptionCycle>,
}

#[derive(Debug)]
pub(crate) enum RuleOutcome {
    /// 单笔账单的全部必填字段都已确定。
    Complete(ParsedRecordPayload),
    /// 需要模型补全；hints 为空表示规则不参与（资产、多笔等）。
    NeedsModel(RuleHints),
}

pub(crate) fn parse_text(text: &str, now: DateTime<FixedOffset>) -> Result<RuleOutcome> {
    let chars: Vec<char> = text.trim().chars().collect();
    if chars.is_empty() || contains_any(text, ASSET_KEYWORDS) {
        return Ok(RuleOutcome::NeedsModel(RuleHints::default()));
    }
    let amounts = find_amounts(&chars);
    if amounts.len() > 1 || text.trim().lines().count() > 1 {
        return Ok(RuleOutcome::NeedsModel(RuleHints::default()));
    }

    let is_income = contains_any(text, INCOME_KEYWORDS);
    let subscription_cycle = subscription_cycle(text);
    let is_subscription = subscription_cycle.is_some() || contains_any(text, SUBSCRIPTION_KEYWORDS);
    let category = if is_income {
        unique_match(text, INCOME_CATEGORY_RULES)
    } else if is_subscription {
        Some("订阅")
    } else {
        unique_match(text, EXPENSE_CATEGORY_RULES)
    };
    let direction = if is_income {
        Some(RecordDirection::Income)
    } else if category.is_some() || contains_any(text, EXPENSE_VERBS) {
        Some(RecordDirection::Expense)
    } else {
        None
    };
    let amount = amounts.first();
    let hints = RuleHints {
        amount: amount.map(|item| item.value),
        currency: amount.and_then(|item| item.currency),
        direction,
        category,
        merchant: unique_match(text, MERCHANT_RULES),
        transaction_at: resolve_time(text, now)?,
        subscription_cycle,
    };

    // 订阅需要模型识别服务名称；缺金额、币种、分类时也交给模型。
    let (Some(amount), Some(currency), Some(direction), Some(category), false) = (
        hints.amount,
        hints.currency,
        hints.direction.clone(),
        hints.category,
        is_subscription,
    ) else {
        return Ok(RuleOutcome::NeedsModel(hints));
    };
    Ok(RuleOutcome::Complete(ParsedRecordPayload {
        direction: Some(direction),
        amount: Some(amount),
        currency: Some(currency.to_string()),
        category: Some(category.to_string()),
        merchant: hints.merchant.map(str::to_string),
        transaction_at: Some(hints.transaction_at.unwrap_or(now).with_timezone(&Utc)),
        note: None,
        subscription_cycle: None,
        asset_info: None,
    }))
}

impl RuleHints {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// 写给模型的已确定字段说明；模型输出仍会被 `apply` 覆盖。
    pub fn prompt_block(&self) -> Option<String> {
        let mut lines = Vec::new();
        if let Some(amount) = self.amount {
            lines.push(format!("- amount: {amount}"));
        }
        if let Some(currency) = self.currency {
            lines.push(format!("- currency: {currency}"));
        }
        if let Some(direction) = &self.direction {
            lines.push(format!("- direction: {}", direction_name(direction)));
        }
        if let Some(category) = self.category {
            lines.push(format!("- category: {category}"));
        }
        if let Some(merchant) = self.merchant {
            lines.push(format!("- merchant: {merchant}"));
        }
        if let Some(cycle) = &self.subscription_cycle {
            lines.push(format!("- subscription_cycle: {}", cycle_name(cycle)));
        }
        if self.transaction_at.is_some() {
            lines.push("- 交易时间已由程序换算，time_text 返回 null".to_string());
        }
        (!lines.is_empty()).then(|| {
            format!(
                "以下字段已由程序确定，输出时保持一致：\n{}",
                lines.join("\n")
            )
        })
    }

    /// 单笔非资产结果才覆盖；多笔或资产说明规则判断与模型不一致，保持模型结果。
    pub fn apply(&self, payloads: &mut [ParsedRecordPayload]) -> bool {
        let [payload] = payloads else {
            return false;
        };
        if payload.asset_info.is_some() {
            return false;
        }
        if let Some(amount) = self.amount {
            payload.amount = Some(amount);
        }
        if let Some(currency) = self.currency {
            payload.currency = Some(currency.to_string());
        }
        if let Some(direction) = &self.direction {
            payload.direction = Some(direction.clone());
        }
        if let Some(category) = self.category {
            payload.category = Some(category.to_string());
        }
        if let Some(merchant) = self.merchant {
            payload.merchant = Some(merchant.to_string());
        }
        if let Some(transaction_at) = self.transaction_at {
            payload.transaction_at = Some(transaction_at.with_timezone(&Utc));
        }
        if let Some(cycle) = &self.subscription_cycle {
            payload.subscription_cycle = Some(cycle.clone());
        }
        true
    }
}

fn direction_name(direction: &RecordDirection) -> &'static str {
    match direction {
        RecordDirection::Income => "income",
        RecordDirection::Expense => "expense",
    }
}

fn cycle_name(cycle: &SubscriptionCycle) -> &'static str {
    match cycle {
        SubscriptionCycle::Monthly => "monthly",
        SubscriptionCycle::Yearly => "yearly",
    }
}

// MARK: - Keywords

const ASSET_KEYWORDS: &[&str] = &["余额", "存款", "持仓", "市值", "资产", "账户里", "账户还有"];

const INCOME_KEYWORDS: &[&str] = &[
    "工资", "薪水", "薪资", "奖金", "收入", "收到", "进账", "到账", "入账", "退款", "退回", "退费",
    "报销", "赚了", "分红", "利息", "收益",
];

const EXPENSE_VERBS: &[&str] = &[
    "花了", "花费", "付了", "支付", "消费", "买了", "买", "交了", "充值", "充了",
];

const SUBSCRIPTION_KEYWORDS: &[&str] = &[
    "订阅", "会员", "续费", "月费", "年费", "包月", "包年", "月付", "年付",
];

const INCOME_CATEGORY_RULES: &[(&str, &[&str])] = &[
    ("工资收入", &["工资", "薪水", "薪资", "奖金"]),
    ("投资收益", &["分红", "利息", "收益", "理财"]),
    ("报销", &["报销"]),
    ("退款", &["退款", "退回", "退费"]),
];

const EXPENSE_CATEGORY_RULES: &[(&str, &[&str])] = &[
    (
        "餐饮",
        &[
            "吃饭",
            "早餐",
            "早饭",
            "午饭",
            "午餐",
            "晚饭",
            "晚餐",
            "夜宵",
            "宵夜",
            "外卖",
            "咖啡",
            "奶茶",
            "饮料",
            "火锅",
            "烧烤",
            "餐厅",
            "饭店",
            "食堂",
            "面包",
            "零食",
            "水果",
            "星巴克",
            "瑞幸",
            "麦当劳",
            "肯德基",
            "喜茶",
        ],
    ),
    (
        "交通",
        &[
            "打车",
            "出租车",
            "滴滴",
            "网约车",
            "地铁",
            "公交",
            "高铁",
            "火车票",
            "机票",
            "加油",
            "油费",
            "停车",
            "过路费",
            "高速费",
            "共享单车",
            "车费",
        ],
    ),
    (
        "日用",
        &[
            "日用品",
            "超市",
            "便利店",
            "纸巾",
            "洗衣液",
            "牙膏",
            "洗发水",
        ],
    ),
    (
        "购物",
        &[
            "衣服",
            "裤子",
            "鞋",
            "包包",
            "淘宝",
            "京东",
            "拼多多",
            "网购",
            "耳机",
            "数码",
        ],
    ),
    (
        "住房",
        &[
            "房租",
            "租金",
            "物业",
            "水费",
            "电费",
            "燃气费",
            "煤气费",
            "水电",
        ],
    ),
    (
        "医疗",
        &[
            "看病", "医院", "买药", "药店", "挂号", "体检", "门诊", "牙医",
        ],
    ),
    (
        "娱乐",
        &[
            "电影",
            "游戏",
            "唱歌",
            "KTV",
            "演唱会",
            "门票",
            "旅游",
            "健身",
        ],
    ),
    (
        "教育",
        &["学费", "培训", "课程", "网课", "买书", "书店", "考试费"],
    ),
    ("通讯", &["话费", "流量", "宽带", "手机费"]),
    ("人情", &["份子钱", "随礼", "礼金", "红包", "请客", "礼物"]),
];

const MERCHANT_RULES: &[(&str, &[&str])] = &[
    ("滴滴出行", &["滴滴"]),
    ("星巴克", &["星巴克"]),
    ("瑞幸咖啡", &["瑞幸"]),
    ("麦当劳", &["麦当劳"]),
    ("肯德基", &["肯德基"]),
    ("喜茶", &["喜茶"]),
    ("淘宝", &["淘宝"]),
    ("京东", &["京东"]),
    ("拼多多", &["拼多多"]),
    ("美团", &["美团"]),
    ("饿了么", &["饿了么"]),
];

fn contains_any(text: &str, keywords: &[&str]) -> bool {
    keywords.iter().any(|keyword| text.contains(keyword))
}

/// 只有恰好一个分组命中时才返回，多个分组同时命中说明有歧义。
fn unique_match(text: &str, rules: &[(&'static str, &[&str])]) -> Option<&'static str> {
    let mut matched = rules
        .iter()
        .filter(|(_, keywords)| contains_any(text, keywords))
        .map(|(name, _)| *name);
    let first = matched.next()?;
    matched.next().is_none().then_some(first)
}

fn subscription_cycle(text: &str) -> Option<SubscriptionCycle> {
    let monthly = contains_any(
        text,
        &["每月", "包月", "月费", "月付", "连续包月", "每个月"],
    );
    let yearly = contains_any(text, &["每年", "包年", "年费", "年付", "每一年"]);
    match (monthly, yearly) {
        (true, false) => Some(SubscriptionCycle::Monthly),
        (false, true) => Some(SubscriptionCycle::Yearly),
        _ => None,
    }
}

// MARK: - Numbers

fn digit_value(c: char) -> Option<u64> {
    match c {
        '0'..='9' => c.to_digit(10).map(u64::from),
        '零' | '〇' => Some(0),
        '一' => Some(1),
        '二' | '两' => Some(2),
        '三' => Some(3),
        '四' => Some(4),
        '五' => Some(5),
        '六' => Some(6),
        '七' => Some(7),
        '八' => Some(8),
        '九' => Some(9),
        _ => None,
    }
}

fn unit_value(c: char) -> Option<u64> {
    match c {
        '十' => Some(10),
        '百' => Some(100),
        '千' => Some(1000),
        '万' => Some(10_000),
        _ => None,
    }
}

fn is_number_char(c: char) -> bool {
    digit_value(c).is_some() || unit_value(c).is_some()
}

/// 解析阿拉伯数字或中文数字（含“两百五”这类口语省略）。
fn parse_number(token: &[char]) -> Option<f64> {
    let text: String = token.iter().collect();
    if token
        .iter()
        .all(|c| c.is_ascii_digit() || *c == '.' || *c == ',')
    {
        return text.replace(',', "").parse().ok();
    }
    let (integer, decimal) = match token.iter().position(|c| *c == '点') {
        Some(index) => (&token[..index], Some(&token[index + 1..])),
        None => (token, None),
    };
    let mut total: u64 = 0;
    let mut section: u64 = 0;
    let mut current: u64 = 0;
    let mut last_unit: u64 = 0;
    let mut zero_seen = false;
    for &c in integer {
        if let Some(digit) = digit_value(c) {
            if c == '零' || c == '〇' {
                zero_seen = true;
            }
            current = current * 10 + digit;
        } else if let Some(unit) = unit_value(c) {
            if unit == 10_000 {
                section += current;
                total += section.max(1) * unit;
                section = 0;
            } else {
                section += current.max(1) * unit;
            }
            current = 0;
            last_unit = unit;
            zero_seen = false;
        } else {
            return None;
        }
    }
    // “两百五”=250、“一千二”=1200：末位裸数字承接上一级单位。
    if current > 0 && current < 10 && last_unit >= 100 && !zero_seen {
        current *= last_unit / 10;
    }
    let mut value = (total + section + current) as f64;
    if let Some(decimal) = decimal {
        let mut scale = 0.1;
        for &c in decimal {
            value += digit_value(c)? as f64 * scale;
            scale /= 10.0;
        }
    }
    Some(value)
}

#[derive(Debug, Clone, PartialEq)]
struct AmountMatch {
    value: f64,
    currency: Option<&'static str>,
}

const CURRENCY_SUFFIXES: &[(&str, &str)] = &[
    ("块钱", "CNY"),
    ("人民币", "CNY"),
    ("美元", "USD"),
    ("美金", "USD"),
    ("港币", "HKD"),
    ("港元", "HKD"),
    ("欧元", "EUR"),
    ("日元", "JPY"),
    ("英镑", "GBP"),
    ("RMB", "CNY"),
    ("rmb", "CNY"),
    ("CNY", "CNY"),
    ("USD", "USD"),
    ("HKD", "HKD"),
    ("EUR", "EUR"),
    ("JPY", "JPY"),
    ("GBP", "GBP"),
    ("块", "CNY"),
    ("元", "CNY"),
    ("刀", "USD"),
];

const CURRENCY_PREFIXES: &[(&str, &str)] = &[
    ("US$", "USD"),
    ("HK$", "HKD"),
    ("¥", "CNY"),
    ("￥", "CNY"),
    ("$", "USD"),
    ("€", "EUR"),
    ("£", "GBP"),
];

/// 紧跟这些字的数字是时间、数量等，不是金额。
const NON_MONEY_SUFFIXES: &[char] = &[
    '点', '天', '号', '日', '月', '年', '分', '时', '个', '次', '杯', '份', '件', '斤', '周', '岁',
    '人', '%',
];

fn starts_with_at(chars: &[char], index: usize, word: &str) -> bool {
    let word: Vec<char> = word.chars().collect();
    chars.len() >= index + word.len() && chars[index..index + word.len()] == word[..]
}

fn ends_with_at(chars: &[char], end: usize, word: &str) -> bool {
    let word: Vec<char> = word.chars().collect();
    end >= word.len() && chars[end - word.len()..end] == word[..]
}

/// `decimals` 为真时把 . , 点 视为小数点/千分位（金额）；日期与钟点不合并。
fn number_runs(chars: &[char], decimals: bool) -> Vec<(usize, usize)> {
    let mut runs = Vec::new();
    let mut index = 0;
    while index < chars.len() {
        if !is_number_char(chars[index]) {
            index += 1;
            continue;
        }
        let start = index;
        while index < chars.len() {
            let c = chars[index];
            let joins_digits = decimals
                && matches!(c, '.' | ',' | '点')
                && index > start
                && index + 1 < chars.len()
                && is_number_char(chars[index + 1]);
            if is_number_char(c) || joins_digits {
                index += 1;
            } else {
                break;
            }
        }
        runs.push((start, index));
    }
    runs
}

fn find_amounts(chars: &[char]) -> Vec<AmountMatch> {
    let mut amounts = Vec::new();
    for (start, end) in number_runs(chars, true) {
        let Some(value) = parse_number(&chars[start..end]).filter(|value| *value > 0.0) else {
            continue;
        };
        let mut after = end;
        while after < chars.len() && chars[after].is_whitespace() {
            after += 1;
        }
        let mut before = start;
        while before > 0 && chars[before - 1].is_whitespace() {
            before -= 1;
        }
        let suffix = CURRENCY_SUFFIXES
            .iter()
            .find(|(word, _)| starts_with_at(chars, after, word))
            .map(|(_, code)| *code);
        let prefix = CURRENCY_PREFIXES
            .iter()
            .find(|(word, _)| ends_with_at(chars, before, word))
            .map(|(_, code)| *code);
        // “一块蛋糕”“两块钱”：单个中文数字 + 块 + 名词是量词，不是金额。
        let is_measure_word = suffix == Some("CNY")
            && end - start == 1
            && !chars[start].is_ascii_digit()
            && starts_with_at(chars, after, "块")
            && !starts_with_at(chars, after, "块钱")
            && chars.get(after + 1).is_some_and(|c| c.is_alphabetic());
        if is_measure_word {
            continue;
        }
        if let Some(currency) = suffix.or(prefix) {
            amounts.push(AmountMatch {
                value,
                currency: Some(currency),
            });
            continue;
        }
        let followed_by_unit = chars
            .get(after)
            .is_some_and(|c| NON_MONEY_SUFFIXES.contains(c));
        let after_verb = EXPENSE_VERBS
            .iter()
            .chain(INCOME_KEYWORDS)
            .any(|verb| ends_with_at(chars, before, verb));
        if after_verb && !followed_by_unit {
            amounts.push(AmountMatch {
                value,
                currency: None,
            });
        }
    }
    amounts
}

// MARK: - Time

#[derive(Debug, Clone, Copy, PartialEq)]
enum Period {
    EarlyMorning,
    Morning,
    Noon,
    Afternoon,
    Evening,
}

/// 时段词及无具体钟点时的默认时间，长词在前。
const PERIOD_WORDS: &[(&str, Period, u32)] = &[
    ("凌晨", Period::EarlyMorning, 5),
    ("清晨", Period::Morning, 7),
    ("早上", Period::Morning, 8),
    ("早晨", Period::Morning, 8),
    ("一早", Period::Morning, 8),
    ("今早", Period::Morning, 8),
    ("昨早", Period::Morning, 8),
    ("上午", Period::Morning, 10),
    ("中午", Period::Noon, 12),
    ("下午", Period::Afternoon, 15),
    ("傍晚", Period::Evening, 18),
    ("深夜", Period::Evening, 23),
    ("半夜", Period::Evening, 23),
    ("晚上", Period::Evening, 20),
    ("今晚", Period::Evening, 20),
    ("昨晚", Period::Evening, 20),
    ("夜里", Period::Evening, 20),
    // 餐次只在没有明确时段词时生效
    ("早餐", Period::Morning, 8),
    ("早饭", Period::Morning, 8),
    ("午饭", Period::Noon, 12),
    ("午餐", Period::Noon, 12),
    ("晚饭", Period::Evening, 19),
    ("晚餐", Period::Evening, 19),
    ("夜宵", Period::Evening, 22),
    ("宵夜", Period::Evening, 22),
];

const DAY_OFFSETS: &[(&str, i64)] = &[
    ("大前天", -3),
    ("前天", -2),
    ("昨天", -1),
    ("昨日", -1),
    ("昨晚", -1),
    ("昨早", -1),
    ("昨夜", -1),
    ("今天", 0),
    ("今日", 0),
    ("今晚", 0),
    ("今早", 0),
    ("明天", 1),
    ("后天", 2),
];

/// 从文本中换算交易时间；没有任何时间线索时返回 None。
pub(crate) fn resolve_time(
    text: &str,
    now: DateTime<FixedOffset>,
) -> Result<Option<DateTime<FixedOffset>>> {
    let chars: Vec<char> = text.chars().collect();
    let today = now.date_naive();
    let date = find_date(&chars, today)?;
    let period = PERIOD_WORDS
        .iter()
        .find(|(word, _, _)| text.contains(word))
        .map(|(_, period, hour)| (*period, *hour));
    let clock = find_clock(&chars)?;

    if date.is_none() && period.is_none() && clock.is_none() {
        return Ok(None);
    }
    let mut date = date.unwrap_or(today);
    let time = match (clock, period) {
        (Some((hour, minute, second)), period) => {
            let (hour, next_day) = adjust_hour(hour, period.map(|(period, _)| period));
            if next_day {
                date += Duration::days(1);
            }
            NaiveTime::from_hms_opt(hour, minute, second)
        }
        (None, Some((_, default_hour))) => NaiveTime::from_hms_opt(default_hour, 0, 0),
        // 只有日期没有时段时沿用当前钟点，保持同日记录的先后顺序。
        (None, None) => Some(now.time()),
    }
    .ok_or_else(|| anyhow!("无法换算时间描述「{text}」"))?;
    now.offset()
        .from_local_datetime(&date.and_time(time))
        .single()
        .map(Some)
        .ok_or_else(|| anyhow!("无法换算时间描述「{text}」"))
}

/// 12 小时制口语换成 24 小时制；返回值第二项表示跨到次日（“晚上12点”）。
fn adjust_hour(hour: u32, period: Option<Period>) -> (u32, bool) {
    match period {
        Some(Period::Afternoon | Period::Evening) if hour == 12 => (0, true),
        Some(Period::Afternoon | Period::Evening) if hour < 12 => (hour + 12, false),
        Some(Period::Noon) if (1..=5).contains(&hour) => (hour + 12, false),
        Some(Period::EarlyMorning) if hour == 12 => (0, false),
        _ => (hour, false),
    }
}

fn find_date(chars: &[char], today: NaiveDate) -> Result<Option<NaiveDate>> {
    let text: String = chars.iter().collect();
    if let Some(date) = find_absolute_date(chars, today)? {
        return Ok(Some(date));
    }
    if let Some(date) = find_week_date(&text, today) {
        return Ok(Some(date));
    }
    // “N 天前”
    for (start, end) in number_runs(chars, false) {
        if starts_with_at(chars, end, "天前") {
            let days = parse_number(&chars[start..end])
                .ok_or_else(|| anyhow!("无法解析天数「{text}」"))?;
            return Ok(Some(today - Duration::days(days as i64)));
        }
    }
    Ok(DAY_OFFSETS
        .iter()
        .find(|(word, _)| text.contains(word))
        .map(|(_, offset)| today + Duration::days(*offset)))
}

fn find_absolute_date(chars: &[char], today: NaiveDate) -> Result<Option<NaiveDate>> {
    let runs = number_runs(chars, false);
    for (index, &(start, end)) in runs.iter().enumerate() {
        let value =
            |range: (usize, usize)| parse_number(&chars[range.0..range.1]).map(|v| v as u32);
        // YYYY-MM-DD / YYYY/MM/DD / YYYY.MM.DD / YYYY年M月D日
        if end - start == 4
            && let (Some(month_run), Some(day_run)) = (runs.get(index + 1), runs.get(index + 2))
            && let Some(separator) = chars.get(end)
            && matches!(separator, '-' | '/' | '.' | '年')
            && month_run.0 == end + 1
            && chars
                .get(month_run.1)
                .is_some_and(|c| *c == *separator || *c == '月')
            && day_run.0 == month_run.1 + 1
        {
            let (Some(year), Some(month), Some(day)) =
                (value((start, end)), value(*month_run), value(*day_run))
            else {
                continue;
            };
            return NaiveDate::from_ymd_opt(year as i32, month, day)
                .map(Some)
                .ok_or_else(|| anyhow!("无效日期 {year}-{month}-{day}"));
        }
        // M月D日 / M月D号：年份取今年，若落在未来则视为去年。
        if chars.get(end) == Some(&'月')
            && let Some(day_run) = runs.get(index + 1)
            && day_run.0 == end + 1
            && chars
                .get(day_run.1)
                .is_some_and(|c| matches!(c, '日' | '号'))
            && !(start > 0 && chars[start - 1] == '年')
        {
            let (Some(month), Some(day)) = (value((start, end)), value(*day_run)) else {
                continue;
            };
            let date = NaiveDate::from_ymd_opt(today.year(), month, day)
                .ok_or_else(|| anyhow!("无效日期 {month}月{day}日"))?;
            if date > today {
                return NaiveDate::from_ymd_opt(today.year() - 1, month, day)
                    .map(Some)
                    .ok_or_else(|| anyhow!("无效日期 {month}月{day}日"));
            }
            return Ok(Some(date));
        }
    }
    Ok(None)
}

fn weekday_index(c: char) -> Option<i64> {
    match c {
        '一' | '1' => Some(0),
        '二' | '2' => Some(1),
        '三' | '3' => Some(2),
        '四' | '4' => Some(3),
        '五' | '5' => Some(4),
        '六' | '6' => Some(5),
        '日' | '天' | '七' | '7' => Some(6),
        _ => None,
    }
}

/// 上周X / 这周X / 周X（周一为一周开始；单独的“周X”取不晚于今天的最近一天）。
fn find_week_date(text: &str, today: NaiveDate) -> Option<NaiveDate> {
    let chars: Vec<char> = text.chars().collect();
    let monday = today - Duration::days(today.weekday().num_days_from_monday() as i64);
    for prefix in [
        "上周",
        "上星期",
        "上礼拜",
        "这周",
        "本周",
        "这星期",
        "本星期",
        "这礼拜",
        "周",
        "星期",
        "礼拜",
    ] {
        let prefix_chars: Vec<char> = prefix.chars().collect();
        for index in 0..chars.len() {
            if !starts_with_at(&chars, index, prefix) {
                continue;
            }
            let Some(day) = chars
                .get(index + prefix_chars.len())
                .and_then(|c| weekday_index(*c))
            else {
                continue;
            };
            let date = match prefix {
                "上周" | "上星期" | "上礼拜" => {
                    monday - Duration::days(7) + Duration::days(day)
                }
                "这周" | "本周" | "这星期" | "本星期" | "这礼拜" => {
                    monday + Duration::days(day)
                }
                _ => {
                    let this_week = monday + Duration::days(day);
                    if this_week > today {
                        this_week - Duration::days(7)
                    } else {
                        this_week
                    }
                }
            };
            return Some(date);
        }
    }
    None
}

/// 解析钟点：HH:MM[:SS]、X点、X点半、X点X分。
fn find_clock(chars: &[char]) -> Result<Option<(u32, u32, u32)>> {
    for index in 0..chars.len() {
        if !chars[index].is_ascii_digit() || (index > 0 && chars[index - 1].is_ascii_digit()) {
            continue;
        }
        let token: String = chars[index..]
            .iter()
            .take_while(|c| c.is_ascii_digit() || **c == ':' || **c == '：')
            .map(|c| if *c == '：' { ':' } else { *c })
            .collect();
        let parts: Vec<&str> = token.split(':').collect();
        if !(2..=3).contains(&parts.len())
            || parts.iter().any(|part| part.is_empty() || part.len() > 2)
        {
            continue;
        }
        let values: Vec<u32> = parts
            .iter()
            .map(|part| part.parse().expect("ascii digits"))
            .collect();
        if values[0] < 24 && values[1] < 60 && values.get(2).is_none_or(|second| *second < 60) {
            return Ok(Some((
                values[0],
                values[1],
                values.get(2).copied().unwrap_or(0),
            )));
        }
    }
    for (start, end) in number_runs(chars, false) {
        let Some(marker) = chars.get(end) else {
            continue;
        };
        if *marker != '点' && *marker != '时' {
            continue;
        }
        let hour = parse_number(&chars[start..end]).ok_or_else(|| anyhow!("无法解析钟点"))? as u32;
        if hour > 24 {
            continue;
        }
        let hour = if hour == 24 { 0 } else { hour };
        let after = end + 1;
        if chars.get(after) == Some(&'半') {
            return Ok(Some((hour, 30, 0)));
        }
        if chars.get(after) == Some(&'一') && chars.get(after + 1) == Some(&'刻') {
            return Ok(Some((hour, 15, 0)));
        }
        let minute_end = (after..chars.len())
            .find(|i| !is_number_char(chars[*i]))
            .unwrap_or(chars.len());
        if minute_end > after {
            let minute = parse_number(&chars[after..minute_end])
                .ok_or_else(|| anyhow!("无法解析分钟"))? as u32;
            if minute < 60 {
                return Ok(Some((hour, minute, 0)));
            }
        }
        return Ok(Some((hour, 0, 0)));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<FixedOffset> {
        // 2026-10-22 是星期四
        DateTime::parse_from_rfc3339("2026-10-22T14:38:45+08:00").unwrap()
    }

    fn time(text: &str) -> String {
        resolve_time(text, now()).unwrap().unwrap().to_rfc3339()
    }

    #[test]
    fn period_words_use_default_hours_instead_of_now() {
        assert_eq!(time("今天早上打车花了100元"), "2026-10-22T08:00:00+08:00");
        assert_eq!(time("中午吃饭"), "2026-10-22T12:00:00+08:00");
        assert_eq!(time("昨晚吃火锅"), "2026-10-21T20:00:00+08:00");
        assert_eq!(time("前天下午买东西"), "2026-10-20T15:00:00+08:00");
        assert_eq!(time("凌晨打车"), "2026-10-22T05:00:00+08:00");
        assert_eq!(time("今天晚上看电影"), "2026-10-22T20:00:00+08:00");
    }

    #[test]
    fn explicit_clock_respects_period() {
        assert_eq!(time("昨天下午2点买东西"), "2026-10-21T14:00:00+08:00");
        assert_eq!(time("晚上8点半打车"), "2026-10-22T20:30:00+08:00");
        assert_eq!(time("早上七点十五分"), "2026-10-22T07:15:00+08:00");
        assert_eq!(time("中午1点吃饭"), "2026-10-22T13:00:00+08:00");
        assert_eq!(time("晚上12点吃夜宵"), "2026-10-23T00:00:00+08:00");
        assert_eq!(time("09:45 买咖啡"), "2026-10-22T09:45:00+08:00");
    }

    #[test]
    fn date_only_keeps_current_clock() {
        assert_eq!(time("昨天打车花了50元"), "2026-10-21T14:38:45+08:00");
        assert_eq!(time("大前天买书"), "2026-10-19T14:38:45+08:00");
        assert_eq!(time("3天前吃饭"), "2026-10-19T14:38:45+08:00");
        assert_eq!(time("三天前吃饭"), "2026-10-19T14:38:45+08:00");
    }

    #[test]
    fn week_and_absolute_dates() {
        assert_eq!(time("上周三加油"), "2026-10-14T14:38:45+08:00");
        assert_eq!(time("周一打车"), "2026-10-19T14:38:45+08:00");
        assert_eq!(time("周六打车"), "2026-10-17T14:38:45+08:00");
        assert_eq!(time("10月3号吃饭"), "2026-10-03T14:38:45+08:00");
        assert_eq!(time("12月30日买票"), "2025-12-30T14:38:45+08:00");
        assert_eq!(time("2026-10-20 08:15:30"), "2026-10-20T08:15:30+08:00");
        assert_eq!(time("2026年9月1日 上午"), "2026-09-01T10:00:00+08:00");
    }

    #[test]
    fn crosses_month_and_year_boundaries() {
        let new_year = DateTime::parse_from_rfc3339("2027-01-01T00:05:06+08:00").unwrap();
        let resolved = resolve_time("昨天下午2点", new_year).unwrap().unwrap();
        assert_eq!(resolved.to_rfc3339(), "2026-12-31T14:00:00+08:00");
    }

    #[test]
    fn no_time_cue_returns_none() {
        assert_eq!(resolve_time("打车花了100元", now()).unwrap(), None);
    }

    #[test]
    fn parses_chinese_numbers() {
        let parse = |text: &str| parse_number(&text.chars().collect::<Vec<_>>()).unwrap();
        assert_eq!(parse("三十"), 30.0);
        assert_eq!(parse("两百五"), 250.0);
        assert_eq!(parse("一千二"), 1200.0);
        assert_eq!(parse("一百零五"), 105.0);
        assert_eq!(parse("三万"), 30000.0);
        assert_eq!(parse("十二点五"), 12.5);
        assert_eq!(parse("1,299.90"), 1299.9);
    }

    #[test]
    fn complete_rule_parse_skips_model() {
        let RuleOutcome::Complete(payload) = parse_text("今天早上打车花了100元", now()).unwrap()
        else {
            panic!("expected complete rule parse");
        };
        assert_eq!(payload.amount, Some(100.0));
        assert_eq!(payload.currency.as_deref(), Some("CNY"));
        assert_eq!(payload.category.as_deref(), Some("交通"));
        assert_eq!(payload.direction, Some(RecordDirection::Expense));
        assert_eq!(
            payload.transaction_at.unwrap().to_rfc3339(),
            "2026-10-22T00:00:00+00:00"
        );
    }

    #[test]
    fn income_and_symbols() {
        let RuleOutcome::Complete(payload) = parse_text("收到工资 ¥12000", now()).unwrap()
        else {
            panic!("expected complete rule parse");
        };
        assert_eq!(payload.direction, Some(RecordDirection::Income));
        assert_eq!(payload.category.as_deref(), Some("工资收入"));
        assert_eq!(payload.amount, Some(12000.0));

        let RuleOutcome::Complete(payload) = parse_text("星巴克咖啡 5.5美元", now()).unwrap()
        else {
            panic!("expected complete rule parse");
        };
        assert_eq!(payload.currency.as_deref(), Some("USD"));
        assert_eq!(payload.merchant.as_deref(), Some("星巴克"));
    }

    #[test]
    fn times_and_counts_are_not_amounts() {
        let RuleOutcome::Complete(payload) =
            parse_text("晚上8点和3个人吃火锅花了三百块", now()).unwrap()
        else {
            panic!("expected complete rule parse");
        };
        assert_eq!(payload.amount, Some(300.0));
        assert_eq!(
            payload.transaction_at.unwrap().to_rfc3339(),
            "2026-10-22T12:00:00+00:00"
        );
    }

    #[test]
    fn incomplete_input_goes_to_model_with_hints() {
        let RuleOutcome::NeedsModel(hints) = parse_text("今天早上在全家花了25", now()).unwrap()
        else {
            panic!("expected model fallback");
        };
        assert_eq!(hints.amount, Some(25.0));
        assert_eq!(hints.currency, None);
        assert_eq!(hints.category, None);
        assert_eq!(
            hints.transaction_at.unwrap().to_rfc3339(),
            "2026-10-22T08:00:00+08:00"
        );
        assert!(hints.prompt_block().unwrap().contains("amount: 25"));
    }

    #[test]
    fn meal_words_yield_to_explicit_periods_and_measure_words_are_not_money() {
        assert_eq!(time("下午吃午饭"), "2026-10-22T15:00:00+08:00");
        let RuleOutcome::NeedsModel(hints) = parse_text("买了一块蛋糕", now()).unwrap()
        else {
            panic!("expected model fallback");
        };
        assert_eq!(hints.amount, None);
    }

    #[test]
    fn ambiguous_category_goes_to_model() {
        let RuleOutcome::NeedsModel(hints) = parse_text("打车去吃饭花了50元", now()).unwrap()
        else {
            panic!("expected model fallback");
        };
        assert_eq!(hints.category, None);
        assert_eq!(hints.amount, Some(50.0));
    }

    #[test]
    fn assets_subscriptions_and_multiple_amounts_go_to_model() {
        for text in ["招商银行存款还有54000元", "打车30元，吃饭50元"] {
            let RuleOutcome::NeedsModel(hints) = parse_text(text, now()).unwrap() else {
                panic!("expected model fallback for {text}");
            };
            assert!(hints.is_empty(), "{text}");
        }
        let RuleOutcome::NeedsModel(hints) =
            parse_text("订阅了 Netflix 每月 15.99 美元", now()).unwrap()
        else {
            panic!("expected model fallback");
        };
        assert_eq!(hints.subscription_cycle, Some(SubscriptionCycle::Monthly));
        assert_eq!(hints.category, Some("订阅"));
        assert_eq!(hints.currency, Some("USD"));
    }

    #[test]
    fn hints_override_single_model_payload() {
        let hints = RuleHints {
            amount: Some(100.0),
            currency: Some("CNY"),
            transaction_at: resolve_time("今天早上", now()).unwrap(),
            ..RuleHints::default()
        };
        let mut payloads = vec![ParsedRecordPayload {
            direction: Some(RecordDirection::Expense),
            amount: Some(10.0),
            currency: None,
            category: Some("交通".to_string()),
            merchant: None,
            transaction_at: Some(now().with_timezone(&Utc)),
            note: None,
            subscription_cycle: None,
            asset_info: None,
        }];
        assert!(hints.apply(&mut payloads));
        assert_eq!(payloads[0].amount, Some(100.0));
        assert_eq!(payloads[0].currency.as_deref(), Some("CNY"));
        assert_eq!(
            payloads[0].transaction_at.unwrap().to_rfc3339(),
            "2026-10-22T00:00:00+00:00"
        );
    }
}
