use super::*;
use crate::{BillRepository, EngineBootstrap};
use base64::Engine;

const PROFILE: &str = "statement-test";
const FIXTURE_EML: &[u8] = include_bytes!("fixtures/cmb_statement.eml");
const FIXTURE_BAD_SUMMARY_EML: &[u8] = include_bytes!("fixtures/cmb_statement_bad_summary.eml");
const FIXTURE_PDF_TEXT: &str = include_str!("fixtures/cmb_statement_pdf_text.txt");

async fn service() -> AppService {
    let path = std::env::temp_dir().join(format!("billlens-statement-{}.sqlite", Uuid::new_v4()));
    AppService::new(
        BillRepository::connect(path).await.unwrap(),
        EngineBootstrap {
            device_id: "test-device".to_string(),
            llm: None,
            log_file_path: None,
            time_zone: "Asia/Shanghai".to_string(),
        },
    )
    .unwrap()
}

fn eml(bytes: &[u8]) -> StatementSourceInput {
    StatementSourceInput {
        kind: StatementSourceKind::Eml,
        content: base64::engine::general_purpose::STANDARD.encode(bytes),
    }
}

fn pdf_text() -> StatementSourceInput {
    StatementSourceInput {
        kind: StatementSourceKind::PdfText,
        content: FIXTURE_PDF_TEXT.to_string(),
    }
}

fn importable_ids(preview: &StatementPreview) -> Vec<Uuid> {
    preview
        .lines
        .iter()
        .filter(|line| line.default_selected)
        .map(|line| line.line_id)
        .collect()
}

async fn record_count(service: &AppService) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM records")
        .fetch_one(service.repo.pool())
        .await
        .unwrap()
}

fn shanghai_noon(month: u32, day: u32) -> DateTime<Utc> {
    chrono_tz::Asia::Shanghai
        .with_ymd_and_hms(2026, month, day, 12, 0, 0)
        .unwrap()
        .with_timezone(&Utc)
}

#[tokio::test]
async fn eml_fixture_parses_sections_dates_categories_and_reconciles() {
    let preview = service()
        .await
        .parse_statement(PROFILE, &eml(FIXTURE_EML))
        .await
        .unwrap();

    assert_eq!(preview.card_last4, vec!["0000"]);
    assert_eq!(
        preview.period_start,
        NaiveDate::from_ymd_opt(2026, 9, 26).unwrap()
    );
    assert_eq!(preview.due_on, NaiveDate::from_ymd_opt(2026, 11, 13));
    assert_eq!(preview.amount_due, Some(1361.59));
    assert!(
        preview.reconciliation.iter().all(|check| check.ok),
        "{:?}",
        preview.reconciliation
    );

    let count = |section| {
        preview
            .lines
            .iter()
            .filter(|l| l.section == section)
            .count()
    };
    assert_eq!(count(StatementSection::Repayment), 1);
    assert_eq!(count(StatementSection::Installment), 2);
    assert_eq!(count(StatementSection::Refund), 2);
    assert_eq!(count(StatementSection::Purchase), 8);

    let repayment = &preview.lines[0];
    assert_eq!(repayment.direction, None);
    assert_eq!(repayment.status, StatementLineStatus::Excluded);
    assert!(!repayment.default_selected);

    // 分期按记账日入账，不是 4 月的首期购买日。
    let installment = &preview.lines[2];
    assert_eq!(installment.transaction_at, shanghai_noon(10, 13));
    assert_eq!(installment.merchant, "苹果在线商店");
    assert_eq!(installment.category, "购物");
    assert_eq!(installment.note, "招行信用卡 尾号0000 · 分期 本金 第7/24期");

    let refund = &preview.lines[3];
    assert_eq!(refund.direction, Some(RecordDirection::Income));
    assert_eq!(refund.category, "退款");
    assert_eq!(refund.amount, 0.06);
    assert_eq!(refund.transaction_at, shanghai_noon(10, 9));

    let categories: Vec<_> = preview.lines[5..]
        .iter()
        .map(|l| l.category.as_str())
        .collect();
    assert_eq!(
        categories,
        vec![
            "日用", "餐饮", "餐饮", "餐饮", "交通", "通讯", "购物", "其他"
        ]
    );
    assert_eq!(preview.lines[5].merchant, "上海盒马网络科技有限公司");
    assert_eq!(preview.lines[5].note, "招行信用卡 尾号0000 · 支付宝");
    assert_eq!(importable_ids(&preview).len(), 12);
}

#[tokio::test]
async fn pdf_text_and_eml_produce_identical_line_ids_amounts_and_dates() {
    let service = service().await;
    let from_eml = service
        .parse_statement(PROFILE, &eml(FIXTURE_EML))
        .await
        .unwrap();
    let from_pdf = service.parse_statement(PROFILE, &pdf_text()).await.unwrap();

    let key = |p: &StatementPreview| -> Vec<(Uuid, String, i64, DateTime<Utc>)> {
        p.lines
            .iter()
            .map(|l| {
                (
                    l.line_id,
                    l.merchant.clone(),
                    to_cents(l.amount),
                    l.transaction_at,
                )
            })
            .collect()
    };
    assert_eq!(key(&from_eml), key(&from_pdf));
    assert!(from_pdf.reconciliation.iter().all(|check| check.ok));
    // 同日同额同商户的两笔得到不同 ID。
    assert_ne!(from_eml.lines[6].line_id, from_eml.lines[7].line_id);
}

#[tokio::test]
async fn tampered_summary_reports_the_difference_but_still_previews() {
    let preview = service()
        .await
        .parse_statement(PROFILE, &eml(FIXTURE_BAD_SUMMARY_EML))
        .await
        .unwrap();
    let new_charges = preview
        .reconciliation
        .iter()
        .find(|check| check.name == "本期新增")
        .unwrap();
    assert!(!new_charges.ok);
    assert_eq!(new_charges.expected, 1400.0);
    assert_eq!(new_charges.actual, 1361.85);
}

#[tokio::test]
async fn reimport_from_any_source_is_idempotent_and_deleted_rows_stay_deleted() {
    let service = service().await;
    let preview = service
        .parse_statement(PROFILE, &eml(FIXTURE_EML))
        .await
        .unwrap();
    let ids = importable_ids(&preview);
    let result = service
        .confirm_statement_import(PROFILE, &eml(FIXTURE_EML), &ids, &HashMap::new())
        .await
        .unwrap();
    assert_eq!((result.inserted, result.skipped_existing), (12, 0));
    assert_eq!(record_count(&service).await, 12);
    assert!(
        result
            .home
            .messages
            .last()
            .unwrap()
            .content
            .contains("已导入招商银行信用卡（尾号0000）2026/09/26–2026/10/25 账单 12 笔")
    );

    service.delete_record(PROFILE, ids[0]).await.unwrap();

    let again = service.parse_statement(PROFILE, &pdf_text()).await.unwrap();
    assert!(
        again
            .lines
            .iter()
            .all(|l| l.status != StatementLineStatus::New)
    );
    assert!(importable_ids(&again).is_empty());
    let deleted = again.lines.iter().find(|l| l.line_id == ids[0]).unwrap();
    assert_eq!(deleted.status, StatementLineStatus::Imported);

    // 绕过预览直接确认，已存在（含软删除）的行被跳过，不复活、不重复。
    let result = service
        .confirm_statement_import(PROFILE, &pdf_text(), &ids, &HashMap::new())
        .await
        .unwrap();
    assert_eq!((result.inserted, result.skipped_existing), (0, 12));
    assert_eq!(record_count(&service).await, 12);
    let live: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM records WHERE deleted_at IS NULL")
        .fetch_one(service.repo.pool())
        .await
        .unwrap();
    assert_eq!(live, 11);
}

#[tokio::test]
async fn manual_records_within_two_days_are_suspected_duplicates_one_to_one() {
    let service = service().await;
    for (amount, at) in [
        (424.83, shanghai_noon(10, 3)),
        (9.90, shanghai_noon(9, 29)),
        (100.0, shanghai_noon(10, 20)),
    ] {
        service
            .repo
            .create_record(
                Uuid::new_v4(),
                PROFILE,
                "test-device",
                RecordCreate {
                    direction: RecordDirection::Expense,
                    amount,
                    currency: "CNY".to_string(),
                    category: "其他".to_string(),
                    merchant: Some("手动".to_string()),
                    transaction_at: at,
                    note: None,
                },
            )
            .await
            .unwrap();
    }

    let preview = service
        .parse_statement(PROFILE, &eml(FIXTURE_EML))
        .await
        .unwrap();
    let duplicates: Vec<_> = preview
        .lines
        .iter()
        .filter(|l| l.status == StatementLineStatus::SuspectedDuplicate)
        .map(|l| (l.merchant.as_str(), l.default_selected))
        .collect();
    // 加油站差 1 天命中；两笔 9.90 只标第一笔；电信差 5 天不命中。
    assert_eq!(
        duplicates,
        vec![
            ("luckincoffee瑞幸咖啡", false),
            ("中海油嘉善姚庄加油站", false)
        ]
    );
    let flagged = preview
        .lines
        .iter()
        .find(|l| l.status == StatementLineStatus::SuspectedDuplicate)
        .unwrap();
    assert_eq!(
        flagged.matched_record.as_ref().unwrap().merchant.as_deref(),
        Some("手动")
    );
}

#[tokio::test]
async fn confirm_rejects_invalid_selections_without_writing() {
    let service = service().await;
    let preview = service
        .parse_statement(PROFILE, &eml(FIXTURE_EML))
        .await
        .unwrap();
    let repayment = preview.lines[0].line_id;
    let purchase = preview.lines[5].line_id;
    let source = eml(FIXTURE_EML);

    let cases: Vec<(Vec<Uuid>, HashMap<Uuid, String>)> = vec![
        (vec![], HashMap::new()),
        (vec![Uuid::new_v4()], HashMap::new()),
        (vec![repayment], HashMap::new()),
        (vec![purchase, purchase], HashMap::new()),
        (
            vec![purchase],
            HashMap::from([(purchase, "工资收入".to_string())]),
        ),
        (
            vec![purchase],
            HashMap::from([(preview.lines[6].line_id, "餐饮".to_string())]),
        ),
    ];
    for (ids, overrides) in cases {
        let error = service
            .confirm_statement_import(PROFILE, &source, &ids, &overrides)
            .await
            .unwrap_err();
        assert!(matches!(error, CoreError::BadRequest(_)), "{error}");
    }
    assert_eq!(record_count(&service).await, 0);

    let result = service
        .confirm_statement_import(
            PROFILE,
            &source,
            &[purchase],
            &HashMap::from([(purchase, "餐饮".to_string())]),
        )
        .await
        .unwrap();
    assert_eq!(result.inserted, 1);
    let record = service.repo.get_record(purchase, PROFILE).await.unwrap();
    assert_eq!(record.category, "餐饮");
    assert_eq!(record.amount, 148.40);
    assert_eq!(record.merchant.as_deref(), Some("上海盒马网络科技有限公司"));
}

#[tokio::test]
async fn injected_insert_failure_rolls_back_every_row_and_message() {
    let service = service().await;
    let preview = service
        .parse_statement(PROFILE, &eml(FIXTURE_EML))
        .await
        .unwrap();
    let ids = importable_ids(&preview);
    let last = ids.last().unwrap().to_string();
    sqlx::raw_sql(&format!(
        "CREATE TRIGGER fail_statement BEFORE INSERT ON records WHEN NEW.id = '{last}' \
         BEGIN SELECT RAISE(ABORT, 'injected failure: statement'); END;"
    ))
    .execute(service.repo.pool())
    .await
    .unwrap();

    let error = service
        .confirm_statement_import(PROFILE, &eml(FIXTURE_EML), &ids, &HashMap::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("injected failure"));
    assert_eq!(record_count(&service).await, 0);
    let messages: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM conversation_messages")
        .fetch_one(service.repo.pool())
        .await
        .unwrap();
    assert_eq!(messages, 0);
}

#[tokio::test]
async fn non_cmb_or_detail_free_sources_are_rejected() {
    let service = service().await;
    let other_bank = String::from_utf8(FIXTURE_EML.to_vec())
        .unwrap()
        .replace("ccsvc@message.cmbchina.com", "bill@example.com")
        .replace(
            "=?utf-8?b?5oub5ZWG6ZO26KGM5L+h55So5Y2h55S15a2Q6LSm5Y2V?=",
            "Statement",
        )
        .replace("=?utf-8?b?5oub5ZWG6ZO26KGM5L+h55So5Y2h?=", "Bank");
    let error = service
        .parse_statement(PROFILE, &eml(other_bank.as_bytes()))
        .await
        .unwrap_err();
    assert!(error.to_string().contains("不是招商银行"), "{error}");
    let html = StatementSourceInput {
        kind: StatementSourceKind::Html,
        content: "<TABLE><TR><TD>2026/09/26-2026/10/25</TD></TR><TR><TD>消费</TD></TR></TABLE>"
            .into(),
    };
    let error = service.parse_statement(PROFILE, &html).await.unwrap_err();
    assert!(error.to_string().contains("不是招商银行"), "{error}");

    let summary_only = StatementSourceInput {
        kind: StatementSourceKind::PdfText,
        content: "招商银行信用卡\n2026/09/26-2026/10/25\n¥ 1.00 ¥ 1.00".into(),
    };
    let error = service
        .parse_statement(PROFILE, &summary_only)
        .await
        .unwrap_err();
    assert!(error.to_string().contains("不含明细"), "{error}");

    let not_eml = StatementSourceInput {
        kind: StatementSourceKind::Eml,
        content: "not base64!".into(),
    };
    assert!(service.parse_statement(PROFILE, &not_eml).await.is_err());
}

/// 真实账单只在本机核对：`BILLLENS_CMB_SAMPLE_EML=/path/x.eml cargo test -- --ignored real_cmb`。
/// 输出只包含计数与勾稽结果，不打印任何交易内容。
#[tokio::test]
#[ignore]
async fn real_cmb_sample_reconciles() {
    let service = service().await;
    for (var, kind) in [
        ("BILLLENS_CMB_SAMPLE_EML", StatementSourceKind::Eml),
        ("BILLLENS_CMB_SAMPLE_PDF_TEXT", StatementSourceKind::PdfText),
    ] {
        let Ok(path) = std::env::var(var) else {
            continue;
        };
        let bytes = std::fs::read(path).unwrap();
        let source = match kind {
            StatementSourceKind::Eml => eml(&bytes),
            _ => StatementSourceInput {
                kind,
                content: String::from_utf8(bytes).unwrap(),
            },
        };
        let preview = service.parse_statement(PROFILE, &source).await.unwrap();
        let mut sections: BTreeMap<&str, usize> = BTreeMap::new();
        for line in &preview.lines {
            *sections.entry(line.section.as_str()).or_default() += 1;
        }
        let ids: Vec<Uuid> = preview.lines.iter().map(|l| l.line_id).collect();
        let checks: Vec<(String, bool)> = preview
            .reconciliation
            .iter()
            .map(|c| (c.name.clone(), c.ok))
            .collect();
        println!(
            "{var}: sections={sections:?} checks={checks:?} id_digest={:x}",
            {
                use std::hash::{Hash, Hasher};
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                ids.hash(&mut hasher);
                hasher.finish()
            }
        );
        assert!(preview.reconciliation.iter().all(|c| c.ok));
    }
}
