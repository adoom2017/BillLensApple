use super::*;
use crate::{BillRepository, EngineBootstrap};
use chrono::{Duration, TimeZone};

const PROFILE: &str = "manual-test";

async fn service() -> AppService {
    let path = std::env::temp_dir().join(format!("billlens-manual-{}.sqlite", Uuid::new_v4()));
    AppService::new(
        BillRepository::connect(path).await.unwrap(),
        EngineBootstrap {
            device_id: "manual-device".to_string(),
            llm: None,
            log_file_path: None,
            time_zone: "Asia/Shanghai".to_string(),
        },
    )
    .unwrap()
}

fn record_input() -> ManualRecordInput {
    ManualRecordInput {
        direction: RecordDirection::Expense,
        amount: 35.5,
        currency: "cny".to_string(),
        category: "餐饮".to_string(),
        merchant: Some("  面馆 ".to_string()),
        transaction_at: chrono_tz::Asia::Shanghai
            .with_ymd_and_hms(2026, 10, 20, 12, 30, 0)
            .unwrap()
            .with_timezone(&Utc),
        note: Some("   ".to_string()),
    }
}

fn subscription_input(first_charge_on: NaiveDate) -> ManualSubscriptionInput {
    ManualSubscriptionInput {
        direction: RecordDirection::Expense,
        amount: 25.0,
        currency: "CNY".to_string(),
        category: "订阅".to_string(),
        merchant: Some("视频会员".to_string()),
        note: None,
        cycle: SubscriptionCycle::Monthly,
        first_charge_on,
    }
}

fn today() -> NaiveDate {
    Utc::now()
        .with_timezone(&chrono_tz::Asia::Shanghai)
        .date_naive()
}

async fn count(service: &AppService, sql: &str) -> i64 {
    sqlx::query_scalar(sql)
        .fetch_one(service.repo.pool())
        .await
        .unwrap()
}

#[tokio::test]
async fn manual_record_is_validated_normalized_and_writes_no_conversation() {
    let service = service().await;
    let record = service
        .create_manual_record(PROFILE, record_input())
        .await
        .unwrap();
    assert_eq!(record.currency, "CNY");
    assert_eq!(record.merchant.as_deref(), Some("面馆"));
    assert_eq!(record.note, None);
    assert_eq!(record.device_id, "manual-device");
    assert_eq!(
        count(&service, "SELECT COUNT(*) FROM conversation_messages").await,
        0
    );
    assert_eq!(
        count(&service, "SELECT COUNT(*) FROM parsed_drafts").await,
        0
    );
}

#[tokio::test]
async fn invalid_manual_records_are_rejected_without_writing() {
    let service = service().await;
    let mut cases = Vec::new();
    let mut zero = record_input();
    zero.amount = 0.0;
    cases.push(zero);
    let mut wrong_direction = record_input();
    wrong_direction.direction = RecordDirection::Income;
    cases.push(wrong_direction);
    let mut unknown_category = record_input();
    unknown_category.category = "火星".to_string();
    cases.push(unknown_category);
    let mut bad_currency = record_input();
    bad_currency.currency = "??".to_string();
    cases.push(bad_currency);
    for input in cases {
        let error = service
            .create_manual_record(PROFILE, input)
            .await
            .unwrap_err();
        assert!(matches!(error, CoreError::BadRequest(_)), "{error}");
    }
    assert_eq!(count(&service, "SELECT COUNT(*) FROM records").await, 0);
}

#[tokio::test]
async fn updating_a_record_bumps_sync_version_and_rejects_other_profiles() {
    let service = service().await;
    let record = service
        .create_manual_record(PROFILE, record_input())
        .await
        .unwrap();
    let mut input = record_input();
    input.direction = RecordDirection::Income;
    input.category = "退款".to_string();
    input.amount = 12.0;
    let updated = service
        .update_record(PROFILE, record.id, input.clone())
        .await
        .unwrap();
    assert_eq!(updated.direction, RecordDirection::Income);
    assert_eq!(updated.amount, 12.0);
    assert_eq!(updated.sync_version, record.sync_version + 1);

    assert!(
        service
            .update_record("other", record.id, input.clone())
            .await
            .is_err()
    );
    service.delete_record(PROFILE, record.id).await.unwrap();
    assert!(
        service
            .update_record(PROFILE, record.id, input)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn future_first_charge_creates_subscription_without_records() {
    let service = service().await;
    let first = today() + Duration::days(10);
    let result = service
        .create_manual_subscription(PROFILE, subscription_input(first))
        .await
        .unwrap();
    assert_eq!(result.charged, 0);
    assert_eq!(result.subscription.next_due_at, first);
    assert_eq!(result.subscription.anchor_day, first.day() as i32);
    assert_eq!(count(&service, "SELECT COUNT(*) FROM records").await, 0);
}

#[tokio::test]
async fn today_first_charge_creates_one_record_and_advances() {
    let service = service().await;
    let result = service
        .create_manual_subscription(PROFILE, subscription_input(today()))
        .await
        .unwrap();
    assert_eq!(result.charged, 1);
    assert!(result.subscription.next_due_at > today());
    assert_eq!(result.subscription.last_charged_at, Some(today()));
    assert_eq!(count(&service, "SELECT COUNT(*) FROM records").await, 1);
}

#[tokio::test]
async fn past_first_charge_backfills_each_cycle_once() {
    let service = service().await;
    let first = today().checked_sub_months(chrono::Months::new(2)).unwrap();
    let result = service
        .create_manual_subscription(PROFILE, subscription_input(first))
        .await
        .unwrap();
    // 两个月前、一个月前、本月（若锚点日已到）。
    let expected = {
        let mut due = first;
        let mut n = 0;
        while due <= today() {
            n += 1;
            due =
                crate::advance_next_due(&SubscriptionCycle::Monthly, first.day() as i32, None, due);
        }
        n
    };
    assert_eq!(result.charged, expected);
    assert_eq!(
        count(&service, "SELECT COUNT(*) FROM records").await,
        expected as i64
    );

    // 再次执行到期维护不会重复扣费。
    let again = service.process_due_subscriptions(PROFILE).await.unwrap();
    assert!(again.is_empty());
    assert_eq!(
        count(&service, "SELECT COUNT(*) FROM records").await,
        expected as i64
    );
}

#[tokio::test]
async fn past_yearly_first_charge_anchors_month_and_day_and_backfills_each_year() {
    let service = service().await;
    let first = today().checked_sub_months(chrono::Months::new(24)).unwrap();
    let mut input = subscription_input(first);
    input.cycle = SubscriptionCycle::Yearly;
    let result = service
        .create_manual_subscription(PROFILE, input)
        .await
        .unwrap();
    assert_eq!(result.subscription.anchor_day, first.day() as i32);
    assert_eq!(result.subscription.anchor_month, Some(first.month() as i32));
    // 两年前、一年前、今年（锚点日不晚于今天）。
    assert_eq!(result.charged, 3);
    assert!(result.subscription.next_due_at > today());
    assert_eq!(count(&service, "SELECT COUNT(*) FROM records").await, 3);
    assert!(
        service
            .process_due_subscriptions(PROFILE)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn invalid_subscription_is_rejected_before_creating_anything() {
    let service = service().await;
    let mut input = subscription_input(today());
    input.amount = -1.0;
    assert!(
        service
            .create_manual_subscription(PROFILE, input)
            .await
            .is_err()
    );
    assert_eq!(
        count(&service, "SELECT COUNT(*) FROM subscriptions").await,
        0
    );
}

#[tokio::test]
async fn manual_asset_creates_then_valuation_updates_same_asset_and_overwrites_same_day() {
    let service = service().await;
    let info = |amount: f64, recorded_on: &str| ParsedAssetInfo {
        name: "招商银行".to_string(),
        category: Some("存款".to_string()),
        amount,
        currency: Some("CNY".to_string()),
        recorded_on: Some(recorded_on.to_string()),
        note: None,
    };
    let created = service
        .create_manual_asset(PROFILE, info(1000.0, "2026-10-01"))
        .await
        .unwrap();
    let updated = service
        .create_manual_asset(PROFILE, info(1200.0, "2026-10-27"))
        .await
        .unwrap();
    let overwritten = service
        .create_manual_asset(PROFILE, info(1300.0, "2026-10-27"))
        .await
        .unwrap();
    assert_eq!(created.asset_id, updated.asset_id);
    assert_eq!(updated.asset_id, overwritten.asset_id);
    assert_eq!(count(&service, "SELECT COUNT(*) FROM assets").await, 1);
    assert_eq!(
        count(
            &service,
            "SELECT COUNT(*) FROM asset_snapshots WHERE deleted_at IS NULL"
        )
        .await,
        2
    );
    let latest: f64 = sqlx::query_scalar(
        "SELECT amount FROM asset_snapshots WHERE recorded_on = '2026-10-27' AND deleted_at IS NULL",
    )
    .fetch_one(service.repo.pool())
    .await
    .unwrap();
    assert_eq!(latest, 1300.0);
    assert_eq!(
        count(&service, "SELECT COUNT(*) FROM conversation_messages").await,
        0
    );

    let mut bad = info(1.0, "2026/10/27");
    assert!(
        service
            .create_manual_asset(PROFILE, bad.clone())
            .await
            .is_err()
    );
    bad.recorded_on = Some("2026-10-27".into());
    bad.category = Some("古董".into());
    assert!(service.create_manual_asset(PROFILE, bad).await.is_err());
}

#[tokio::test]
async fn manual_entry_transaction_rolls_back_on_failure() {
    let service = service().await;
    sqlx::raw_sql(
        "CREATE TRIGGER fail_snapshot BEFORE INSERT ON asset_snapshots \
         BEGIN SELECT RAISE(ABORT, 'injected failure: snapshot'); END;",
    )
    .execute(service.repo.pool())
    .await
    .unwrap();
    let error = service
        .create_manual_asset(
            PROFILE,
            ParsedAssetInfo {
                name: "现金".into(),
                category: Some("现金".into()),
                amount: 10.0,
                currency: Some("CNY".into()),
                recorded_on: Some("2026-10-27".into()),
                note: None,
            },
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("injected failure"));
    assert_eq!(count(&service, "SELECT COUNT(*) FROM assets").await, 0);
}

#[tokio::test]
async fn same_name_asset_in_another_currency_is_a_user_facing_rejection() {
    let service = service().await;
    let info = |currency: &str| ParsedAssetInfo {
        name: "招商银行".to_string(),
        category: Some("存款".to_string()),
        amount: 100.0,
        currency: Some(currency.to_string()),
        recorded_on: Some("2026-10-27".to_string()),
        note: None,
    };
    service
        .create_manual_asset(PROFILE, info("CNY"))
        .await
        .unwrap();
    let error = service
        .create_manual_asset(PROFILE, info("USD"))
        .await
        .unwrap_err();
    let CoreError::BadRequest(message) = error else {
        panic!("expected BadRequest, got {error}");
    };
    assert!(message.contains("已使用 CNY 记账"), "{message}");
    let currency: String = sqlx::query_scalar("SELECT currency FROM assets")
        .fetch_one(service.repo.pool())
        .await
        .unwrap();
    assert_eq!(currency, "CNY");
}
