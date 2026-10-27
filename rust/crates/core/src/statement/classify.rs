//! 账单摘要 → 商户、渠道、固定分类。纯数据规则，按顺序命中即停。

/// 支付渠道前缀，按长度从长到短，避免「美团支付-」被「美团」误匹配。
const CHANNEL_PREFIXES: &[(&str, &str)] = &[
    ("拼多多支付-", "拼多多"),
    ("美团支付-", "美团"),
    ("京东支付-", "京东"),
    ("抖音支付-", "抖音"),
    ("微信支付-", "微信"),
    ("云闪付-", "云闪付"),
    ("支付宝-", "支付宝"),
    ("财付通-", "财付通"),
    ("银联-", "银联"),
];

const CATEGORY_RULES: &[(&str, &[&str])] = &[
    ("通讯", &["中国电信", "中国移动", "中国联通", "话费"]),
    (
        "医疗",
        &["药房", "药店", "医院", "诊所", "阿里健康", "医药"],
    ),
    (
        "交通",
        &[
            "加油站",
            "中石化",
            "中石油",
            "中海油",
            "滴滴",
            "铁路",
            "12306",
            "地铁",
            "停车",
            "高德打车",
            "航空",
        ],
    ),
    (
        "日用",
        &[
            "盒马",
            "便利",
            "喜士多",
            "全家",
            "罗森",
            "超市",
            "壹佰米",
            "叮咚",
            "朴朴",
            "物美",
        ],
    ),
    (
        "餐饮",
        &[
            "咖啡",
            "瑞幸",
            "luckin",
            "星巴克",
            "面包",
            "餐厅",
            "餐饮",
            "饭",
            "面",
            "粥",
            "包子",
            "水煎包",
            "拉扎斯",
            "饿了么",
            "三快",
            "食",
            "茶",
            "肯德基",
            "麦当劳",
        ],
    ),
    (
        "娱乐",
        &[
            "旅行社",
            "飞猪",
            "携程",
            "电影",
            "影城",
            "文化",
            "景区",
            "酒店",
        ],
    ),
    (
        "购物",
        &[
            "苹果在线商店",
            "apple",
            "旗舰店",
            "苏宁",
            "京东",
            "名创优品",
            "数码",
            "天猫",
            "淘宝",
            "百货",
        ],
    ),
];

/// 关键词都没命中时按支付渠道兜底。
const CHANNEL_FALLBACK: &[(&str, &str)] = &[("拼多多", "购物"), ("美团", "餐饮"), ("京东", "购物")];

pub(crate) struct ClassifiedDescription {
    pub merchant: String,
    pub channel: Option<&'static str>,
    /// 分期期数等附加说明，如「本金 第14/24期」。
    pub detail: Option<String>,
}

pub(crate) fn split_description(description: &str) -> ClassifiedDescription {
    if let Some(rest) = description.strip_prefix("消费分期-") {
        let (merchant, detail) = match rest.split_once(' ') {
            Some((merchant, detail)) => (merchant, Some(detail.to_string())),
            None => (rest, None),
        };
        return ClassifiedDescription {
            merchant: merchant.to_string(),
            channel: None,
            detail,
        };
    }
    for (prefix, channel) in CHANNEL_PREFIXES {
        if let Some(rest) = description.strip_prefix(prefix) {
            // 美团商户名前带「美团」，但美团自身（北京三快）保留原名。
            let merchant = match *channel {
                "美团" if !rest.contains("三快") => rest.strip_prefix("美团").unwrap_or(rest),
                _ => rest,
            };
            let merchant = if merchant.is_empty() { rest } else { merchant };
            return ClassifiedDescription {
                merchant: merchant.to_string(),
                channel: Some(channel),
                detail: None,
            };
        }
    }
    ClassifiedDescription {
        merchant: description.to_string(),
        channel: None,
        detail: None,
    }
}

pub(crate) fn expense_category(description: &str, channel: Option<&str>) -> &'static str {
    let haystack = description.to_lowercase();
    for (category, keywords) in CATEGORY_RULES {
        if keywords.iter().any(|keyword| haystack.contains(keyword)) {
            return category;
        }
    }
    channel
        .and_then(|channel| {
            CHANNEL_FALLBACK
                .iter()
                .find(|(name, _)| *name == channel)
                .map(|(_, category)| *category)
        })
        .unwrap_or("其他")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn classify(description: &str) -> (String, &'static str) {
        let split = split_description(description);
        (
            split.merchant.clone(),
            expense_category(description, split.channel),
        )
    }

    #[test]
    fn strips_channel_prefixes_and_keeps_meituan_itself() {
        assert_eq!(
            classify("支付宝-上海盒马网络科技有限公司"),
            ("上海盒马网络科技有限公司".into(), "日用")
        );
        assert_eq!(
            classify("美团支付-美团三阿嬷爆炒鲜牛肉饭（滨江宝"),
            ("三阿嬷爆炒鲜牛肉饭（滨江宝".into(), "餐饮")
        );
        assert_eq!(
            classify("美团支付-美团北京三快在线科技有限公司"),
            ("美团北京三快在线科技有限公司".into(), "餐饮")
        );
        assert_eq!(
            classify("拼多多支付-折腾Z桌搭"),
            ("折腾Z桌搭".into(), "购物")
        );
        assert_eq!(classify("财付通-luckincoffee瑞幸咖啡").1, "餐饮");
    }

    #[test]
    fn maps_sample_merchants_to_fixed_categories() {
        for (description, category) in [
            ("支付宝-中海油嘉善姚庄加油站", "交通"),
            ("财付通-中国电信", "通讯"),
            ("支付宝-阿里健康大药房医药连锁有限公", "医疗"),
            ("支付宝-飞猪国际旅行社（浙江）有限公", "娱乐"),
            ("支付宝-上海拉扎斯信息科技有限公司", "餐饮"),
            ("支付宝-苏宁易购集团股份有限公司苏宁", "购物"),
            ("支付宝-杭州市滨江区财政局", "其他"),
        ] {
            assert_eq!(classify(description).1, category, "{description}");
        }
    }

    #[test]
    fn installment_description_splits_merchant_and_term() {
        let split = split_description("消费分期-苹果在线商店 本金 第14/24期");
        assert_eq!(split.merchant, "苹果在线商店");
        assert_eq!(split.detail.as_deref(), Some("本金 第14/24期"));
        assert_eq!(
            expense_category("消费分期-苹果在线商店 本金 第14/24期", None),
            "购物"
        );
    }
}
