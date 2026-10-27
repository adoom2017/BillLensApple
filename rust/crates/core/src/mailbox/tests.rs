use super::*;
use crate::{BillRepository, EngineBootstrap, RecordCreate, RecordDirection};
use chrono::{Duration, TimeZone};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use uuid::Uuid;

const PROFILE: &str = "mailbox-test";
const TOKEN: &str = "test-token";
const STATEMENT: &[u8] = include_bytes!("../statement/fixtures/cmb_statement.eml");
const BAD_SUMMARY: &[u8] = include_bytes!("../statement/fixtures/cmb_statement_bad_summary.eml");
const REMINDER: &[u8] = b"From: ccsvc@message.cmbchina.com\r\nSubject: =?utf-8?b?6L+Y5qy+5o+Q6YaS?=\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>\xe8\xaf\xb7\xe6\x8c\x89\xe6\x97\xb6\xe8\xbf\x98\xe6\xac\xbe</p>\r\n";

#[derive(Default)]
struct MockState {
    messages: Vec<(String, DateTime<Utc>, Vec<u8>)>,
    /// 列表返回的固定状态码（如 401），None 为正常。
    list_status: Option<u16>,
    /// 下载这些 ID 时返回 503。
    failing_mime: Vec<String>,
    mime_requests: Vec<String>,
    /// 列表请求中 `ge` 之后的时间，用于断言游标。
    list_since: Vec<String>,
}

/// 极简 HTTP 模拟 Graph：每个连接一个请求，按路径路由；分页每页 2 封。
async fn mock_graph(state: Arc<Mutex<MockState>>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/v1.0", listener.local_addr().unwrap());
    let base_for_server = base.clone();
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let state = state.clone();
            let base = base_for_server.clone();
            tokio::spawn(async move {
                let mut buffer = Vec::new();
                let mut chunk = [0u8; 4096];
                while !buffer.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = socket.read(&mut chunk).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    buffer.extend_from_slice(&chunk[..n]);
                }
                let request = String::from_utf8_lossy(&buffer).to_string();
                let target = request.split_whitespace().nth(1).unwrap_or("/").to_string();
                let authorized = request.contains(&format!("authorization: Bearer {TOKEN}"))
                    || request.contains(&format!("Authorization: Bearer {TOKEN}"));
                let (status, body) = route(&state, &base, &target, authorized);
                let head = format!(
                    "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                socket.write_all(head.as_bytes()).await.unwrap();
                socket.write_all(&body).await.unwrap();
            });
        }
    });
    base
}

fn route(
    state: &Arc<Mutex<MockState>>,
    base: &str,
    target: &str,
    authorized: bool,
) -> (u16, Vec<u8>) {
    let mut state = state.lock().unwrap();
    if !authorized {
        return (401, b"{}".to_vec());
    }
    let url = reqwest::Url::parse(&format!("http://mock{target}")).unwrap();
    let path = url.path().trim_start_matches("/v1.0");
    if path == "/me/messages" {
        if let Some(status) = state.list_status {
            return (status, b"{}".to_vec());
        }
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        let filter = query.get("$filter").cloned().unwrap_or_default();
        assert!(filter.contains(source::STATEMENT_SENDER), "{filter}");
        let since_text = filter
            .split("ge ")
            .nth(1)
            .unwrap()
            .split(' ')
            .next()
            .unwrap()
            .to_string();
        state.list_since.push(since_text.clone());
        let since = DateTime::parse_from_rfc3339(&since_text)
            .unwrap()
            .with_timezone(&Utc);
        let skip: usize = query.get("skip").and_then(|s| s.parse().ok()).unwrap_or(0);
        let mut matching: Vec<_> = state
            .messages
            .iter()
            .filter(|(_, at, _)| *at >= since)
            .collect();
        matching.sort_by_key(|(_, at, _)| *at);
        let page: Vec<_> = matching.iter().skip(skip).take(2).collect();
        let value: Vec<_> = page
            .iter()
            .map(|(id, at, _)| serde_json::json!({ "id": id, "receivedDateTime": at.to_rfc3339() }))
            .collect();
        let mut body = serde_json::json!({ "value": value });
        if skip + 2 < matching.len() {
            body["@odata.nextLink"] = serde_json::json!(format!(
                "{base}/me/messages?skip={}&$filter={}",
                skip + 2,
                urlencode(&filter)
            ));
        }
        return (200, body.to_string().into_bytes());
    }
    if let Some(id) = path
        .strip_prefix("/me/messages/")
        .and_then(|rest| rest.strip_suffix("/$value"))
    {
        let id = id.to_string();
        state.mime_requests.push(id.clone());
        if state.failing_mime.contains(&id) {
            return (503, b"{}".to_vec());
        }
        return match state.messages.iter().find(|(mid, _, _)| *mid == id) {
            Some((_, _, mime)) => (200, mime.clone()),
            None => (404, b"{}".to_vec()),
        };
    }
    (404, b"{}".to_vec())
}

fn urlencode(text: &str) -> String {
    reqwest::Url::parse_with_params("http://x", &[("f", text)])
        .unwrap()
        .query()
        .unwrap()
        .trim_start_matches("f=")
        .to_string()
}

async fn service() -> AppService {
    let path = std::env::temp_dir().join(format!("billlens-mailbox-{}.sqlite", Uuid::new_v4()));
    AppService::new(
        BillRepository::connect(path).await.unwrap(),
        EngineBootstrap {
            device_id: "mail-device".to_string(),
            llm: None,
            log_file_path: None,
            time_zone: "Asia/Shanghai".to_string(),
        },
    )
    .unwrap()
}

fn days_ago(days: i64) -> DateTime<Utc> {
    Utc::now() - Duration::days(days)
}

async fn sync(service: &AppService, base: &str) -> MailboxSyncResult {
    sync_months(service, base, DEFAULT_LOOKBACK_MONTHS).await
}

async fn sync_months(service: &AppService, base: &str, months: u32) -> MailboxSyncResult {
    graph_sync(service, base, months).await.unwrap()
}

async fn graph_sync(
    service: &AppService,
    base: &str,
    months: u32,
) -> Result<MailboxSyncResult, CoreError> {
    let client = GraphClient::new(base);
    let mut source = GraphSource {
        client: &client,
        access_token: TOKEN,
    };
    service
        .sync_mailbox_with(&mut source, PROFILE, "me@hotmail.com", months)
        .await
}

async fn record_count(service: &AppService) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM records")
        .fetch_one(service.repo.pool())
        .await
        .unwrap()
}

#[tokio::test]
async fn reconciled_statement_is_auto_imported_and_reminders_are_skipped_across_pages() {
    let state = Arc::new(Mutex::new(MockState {
        messages: vec![
            ("reminder-1".into(), days_ago(20), REMINDER.to_vec()),
            ("statement-1".into(), days_ago(10), STATEMENT.to_vec()),
            ("reminder-2".into(), days_ago(5), REMINDER.to_vec()),
        ],
        ..Default::default()
    }));
    let base = mock_graph(state.clone()).await;
    let service = service().await;

    let result = sync(&service, &base).await;
    assert_eq!(result.imported, 12);
    assert_eq!(result.skipped, 2);
    assert_eq!(result.scanned, 3);
    assert_eq!(result.new_pending_statements, 0);
    assert!(!result.needs_reauth);
    assert_eq!(result.error, None);
    assert!(result.pending.is_empty());
    assert_eq!(record_count(&service).await, 12);
    assert!(
        result
            .home
            .messages
            .last()
            .unwrap()
            .content
            .starts_with("已从邮箱自动导入招商银行信用卡")
    );
    let state_row = result.state.unwrap();
    assert_eq!(state_row.account_address, "me@hotmail.com");
    assert!(state_row.cursor.is_some());

    // 第二轮：从游标继续，已处理的邮件不再下载，也不重复入账。
    let downloads_before = state.lock().unwrap().mime_requests.len();
    let again = sync(&service, &base).await;
    assert_eq!((again.imported, again.skipped), (0, 0));
    assert_eq!(state.lock().unwrap().mime_requests.len(), downloads_before);
    assert_eq!(record_count(&service).await, 12);
    let since = state.lock().unwrap().list_since.clone();
    assert_eq!(since.len(), 3, "首轮两页 + 第二轮一页");
    assert_ne!(since[0], since[2], "第二轮应从游标开始");
}

#[tokio::test]
async fn suspected_duplicates_are_held_for_review_while_the_rest_is_imported() {
    let state = Arc::new(Mutex::new(MockState {
        messages: vec![("statement-1".into(), days_ago(3), STATEMENT.to_vec())],
        ..Default::default()
    }));
    let base = mock_graph(state).await;
    let service = service().await;
    // 与账单中 10/01 的 424.83 加油站消费金额相同、同一天的手动记录。
    service
        .repo
        .create_record(
            Uuid::new_v4(),
            PROFILE,
            "mail-device",
            RecordCreate {
                direction: RecordDirection::Expense,
                amount: 424.83,
                currency: "CNY".into(),
                category: "交通".into(),
                merchant: Some("加油".into()),
                transaction_at: chrono_tz::Asia::Shanghai
                    .with_ymd_and_hms(2026, 10, 1, 9, 0, 0)
                    .unwrap()
                    .with_timezone(&Utc),
                note: None,
            },
        )
        .await
        .unwrap();

    let result = sync(&service, &base).await;
    assert_eq!(result.imported, 11);
    assert_eq!(result.new_pending_statements, 1);
    assert_eq!(result.pending.len(), 1);
    assert_eq!(result.pending[0].pending_count, 1);
    assert_eq!(result.pending[0].imported_count, 11);
    assert_eq!(
        result.pending[0].period_label.as_deref(),
        Some("2026/09/26–2026/10/25")
    );

    // 打开待确认：预览中已自动入账的行显示为已导入，只剩疑似重复一行可选。
    let source = service
        .mail_statement_source(PROFILE, "statement-1")
        .await
        .unwrap();
    let preview = service.parse_statement(PROFILE, &source).await.unwrap();
    let open: Vec<_> = preview
        .lines
        .iter()
        .filter(|l| l.direction.is_some() && l.status != StatementLineStatus::Imported)
        .collect();
    assert_eq!(open.len(), 1);
    assert_eq!(open[0].status, StatementLineStatus::SuspectedDuplicate);

    let status = service
        .resolve_mail_statement(PROFILE, "statement-1")
        .await
        .unwrap();
    assert!(status.pending.is_empty());
    assert!(
        service
            .mail_statement_source(PROFILE, "statement-1")
            .await
            .is_err()
    );
}

#[tokio::test]
async fn unreconciled_statement_is_held_entirely_for_review() {
    let state = Arc::new(Mutex::new(MockState {
        messages: vec![("bad".into(), days_ago(3), BAD_SUMMARY.to_vec())],
        ..Default::default()
    }));
    let base = mock_graph(state).await;
    let service = service().await;

    let result = sync(&service, &base).await;
    assert_eq!(result.imported, 0);
    assert_eq!(result.new_pending_statements, 1);
    assert_eq!(result.pending[0].pending_count, 12);
    assert_eq!(record_count(&service).await, 0);
}

#[tokio::test]
async fn unauthorized_requests_report_reauth_without_moving_the_cursor() {
    let state = Arc::new(Mutex::new(MockState {
        list_status: Some(401),
        ..Default::default()
    }));
    let base = mock_graph(state).await;
    let service = service().await;

    let result = sync(&service, &base).await;
    assert!(result.needs_reauth);
    assert!(result.error.is_some());
    assert_eq!(result.state.unwrap().cursor, None);
}

#[tokio::test]
async fn download_failure_stops_before_the_failed_mail_and_resumes_next_time() {
    let state = Arc::new(Mutex::new(MockState {
        messages: vec![
            ("reminder".into(), days_ago(9), REMINDER.to_vec()),
            ("statement".into(), days_ago(4), STATEMENT.to_vec()),
        ],
        failing_mime: vec!["statement".into()],
        ..Default::default()
    }));
    let base = mock_graph(state.clone()).await;
    let service = service().await;

    let first = sync(&service, &base).await;
    assert_eq!(first.skipped, 1);
    assert_eq!(first.imported, 0);
    assert!(!first.needs_reauth);
    assert!(first.error.as_deref().unwrap().contains("限流"));
    let cursor = first.state.unwrap().cursor.unwrap();
    assert!(cursor < days_ago(8), "游标只推进到成功处理的提醒邮件");

    state.lock().unwrap().failing_mime.clear();
    let second = sync(&service, &base).await;
    assert_eq!(second.imported, 12);
    assert_eq!(second.skipped, 0, "已跳过的提醒邮件不会再处理");
    assert_eq!(second.error, None);
}

#[tokio::test]
async fn disconnect_clears_state_but_keeps_imported_records() {
    let state = Arc::new(Mutex::new(MockState {
        messages: vec![("bad".into(), days_ago(3), BAD_SUMMARY.to_vec())],
        ..Default::default()
    }));
    let base = mock_graph(state).await;
    let service = service().await;
    sync(&service, &base).await;
    service
        .repo
        .create_record(
            Uuid::new_v4(),
            PROFILE,
            "mail-device",
            RecordCreate {
                direction: RecordDirection::Expense,
                amount: 1.0,
                currency: "CNY".into(),
                category: "其他".into(),
                merchant: None,
                transaction_at: Utc::now(),
                note: None,
            },
        )
        .await
        .unwrap();

    service.disconnect_mailbox(PROFILE).await.unwrap();
    let status = service.mailbox_status(PROFILE).await.unwrap();
    assert!(status.state.is_none());
    assert!(status.pending.is_empty());
    let raw_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM mail_messages")
        .fetch_one(service.repo.pool())
        .await
        .unwrap();
    assert_eq!(raw_rows, 0);
    assert_eq!(record_count(&service).await, 1);
}

#[tokio::test]
async fn foreign_next_links_are_refused_so_tokens_never_leave_graph() {
    for foreign in ["https://evil.example/steal", "{base}.evil.example/steal"] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/v1.0", listener.local_addr().unwrap());
        let next = foreign.replace("{base}", &base);
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buffer = [0u8; 4096];
            let _ = socket.read(&mut buffer).await.unwrap();
            let body = format!(r#"{{"value":[],"@odata.nextLink":"{next}"}}"#);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                body.len()
            );
            socket.write_all(head.as_bytes()).await.unwrap();
            socket.write_all(body.as_bytes()).await.unwrap();
        });
        let error = GraphClient::new(&base)
            .list_statement_messages(TOKEN, Utc::now())
            .await
            .unwrap_err();
        assert!(matches!(error, MailboxError::Decode(_)), "{foreign}");
    }
}

#[tokio::test]
async fn reprocessing_after_disconnect_adds_no_records_or_assistant_messages() {
    let state = Arc::new(Mutex::new(MockState {
        messages: vec![("statement".into(), days_ago(4), STATEMENT.to_vec())],
        ..Default::default()
    }));
    let base = mock_graph(state).await;
    let service = service().await;
    assert_eq!(sync(&service, &base).await.imported, 12);
    let messages = |service: &AppService| {
        let pool = service.repo.pool().clone();
        async move {
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM conversation_messages")
                .fetch_one(&pool)
                .await
                .unwrap()
        }
    };
    let before = messages(&service).await;

    service.disconnect_mailbox(PROFILE).await.unwrap();
    let again = sync(&service, &base).await;
    assert_eq!((again.imported, again.new_pending_statements), (0, 0));
    assert_eq!(record_count(&service).await, 12);
    assert_eq!(messages(&service).await, before);
}

#[tokio::test]
async fn widening_the_window_rescans_older_mail_and_narrowing_does_not() {
    let state = Arc::new(Mutex::new(MockState {
        messages: vec![
            ("old-reminder".into(), days_ago(150), REMINDER.to_vec()),
            ("recent-reminder".into(), days_ago(10), REMINDER.to_vec()),
        ],
        ..Default::default()
    }));
    let base = mock_graph(state.clone()).await;
    let service = service().await;

    let first = sync_months(&service, &base, 3).await;
    assert_eq!(first.skipped, 1, "3 个月窗口外的邮件不处理");
    assert!(first.state.unwrap().cursor.is_some());

    let widened = sync_months(&service, &base, 6).await;
    assert_eq!(widened.skipped, 1, "调大后补扫更早的邮件");
    assert_eq!(
        state.lock().unwrap().mime_requests,
        vec!["recent-reminder", "old-reminder"],
        "已处理的邮件不重复下载"
    );

    let narrowed = sync_months(&service, &base, 1).await;
    assert_eq!(narrowed.skipped, 0);
    let since = state.lock().unwrap().list_since.last().cloned().unwrap();
    let since = DateTime::parse_from_rfc3339(&since).unwrap();
    assert!(
        since > days_ago(11),
        "调小月数不重置游标，仍从最近一封之后继续"
    );

    let invalid = graph_sync(&service, &base, 0).await;
    assert!(invalid.is_err());
}

// ---- iCloud（IMAP）----

const IMAP_PASSWORD: &str = "app-specific-pass";
/// 模拟服务器对这个密码返回 `NO [UNAVAILABLE]`（临时故障）。
const IMAP_UNAVAILABLE_PASSWORD: &str = "server-unavailable";

#[derive(Default)]
struct ImapMockState {
    /// (uid, 接收时间, MIME)
    messages: Vec<(u32, DateTime<Utc>, Vec<u8>)>,
    commands: Vec<String>,
    mime_requests: Vec<u32>,
}

/// 极简 IMAP 模拟：只实现同步用到的 LOGIN / EXAMINE / UID SEARCH / UID FETCH / LOGOUT。
async fn mock_imap(state: Arc<Mutex<ImapMockState>>) -> std::net::SocketAddr {
    use tokio::io::AsyncBufReadExt;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (socket, _) = listener.accept().await.unwrap();
            let state = state.clone();
            tokio::spawn(async move {
                let (read, mut write) = socket.into_split();
                let mut lines = tokio::io::BufReader::new(read).lines();
                write.write_all(b"* OK IMAP ready\r\n").await.unwrap();
                while let Ok(Some(line)) = lines.next_line().await {
                    let (tag, command) = line.split_once(' ').unwrap();
                    let reply = imap_reply(&state, tag, command);
                    write.write_all(&reply).await.unwrap();
                    if command.starts_with("LOGOUT") {
                        return;
                    }
                }
            });
        }
    });
    addr
}

fn imap_reply(state: &Arc<Mutex<ImapMockState>>, tag: &str, command: &str) -> Vec<u8> {
    let mut state = state.lock().unwrap();
    state.commands.push(command.to_string());
    let ok = format!("{tag} OK done\r\n");
    if command.starts_with("LOGIN") {
        return if command.contains(IMAP_PASSWORD) {
            ok.into_bytes()
        } else if command.contains(IMAP_UNAVAILABLE_PASSWORD) {
            format!("{tag} NO [UNAVAILABLE] Temporary failure.\r\n").into_bytes()
        } else {
            format!("{tag} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n").into_bytes()
        };
    }
    if command.starts_with("EXAMINE") {
        return format!(
            "* {} EXISTS\r\n* OK [UIDVALIDITY 7] UIDs valid\r\n{tag} OK [READ-ONLY] EXAMINE completed\r\n",
            state.messages.len()
        )
        .into_bytes();
    }
    if let Some(query) = command.strip_prefix("UID SEARCH ") {
        assert!(query.contains(source::STATEMENT_SENDER), "{query}");
        let day = query.split_whitespace().nth(1).unwrap();
        let since = chrono::NaiveDate::parse_from_str(day, "%d-%b-%Y").unwrap();
        let uids: Vec<String> = state
            .messages
            .iter()
            .filter(|(_, at, _)| at.date_naive() >= since)
            .map(|(uid, _, _)| uid.to_string())
            .collect();
        return format!("* SEARCH {}\r\n{ok}", uids.join(" ")).into_bytes();
    }
    if let Some(rest) = command.strip_prefix("UID FETCH ") {
        let (set, items) = rest.split_once(' ').unwrap();
        let wanted: Vec<u32> = set.split(',').map(|uid| uid.parse().unwrap()).collect();
        let mut reply = Vec::new();
        for (index, (uid, at, mime)) in state.messages.clone().iter().enumerate() {
            if !wanted.contains(uid) {
                continue;
            }
            if items.contains("BODY.PEEK[]") {
                state.mime_requests.push(*uid);
                reply.extend(
                    format!(
                        "* {} FETCH (UID {uid} BODY[] {{{}}}\r\n",
                        index + 1,
                        mime.len()
                    )
                    .into_bytes(),
                );
                reply.extend_from_slice(mime);
                reply.extend_from_slice(b")\r\n");
            } else {
                assert!(items.contains("ENVELOPE"), "{items}");
                reply.extend(
                    format!(
                        "* {} FETCH (UID {uid} INTERNALDATE \"{}\" ENVELOPE (NIL \"{}\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n",
                        index + 1,
                        at.format("%d-%b-%Y %H:%M:%S +0000"),
                        raw_subject(mime)
                    )
                    .into_bytes(),
                );
            }
        }
        reply.extend(ok.into_bytes());
        return reply;
    }
    if command.starts_with("LOGOUT") {
        return format!("* BYE\r\n{ok}").into_bytes();
    }
    format!("{tag} BAD unsupported\r\n").into_bytes()
}

/// MIME 中 `Subject:` 的原始（RFC 2047 编码）值，供信封使用。
fn raw_subject(mime: &[u8]) -> String {
    String::from_utf8_lossy(mime)
        .lines()
        .find_map(|line| line.strip_prefix("Subject: "))
        .unwrap_or("")
        .trim()
        .to_string()
}

async fn imap_sync(
    service: &AppService,
    addr: std::net::SocketAddr,
    password: &str,
) -> MailboxSyncResult {
    let mut source = ImapSource::plain(addr, "me@icloud.com", password);
    let result = service
        .sync_mailbox_with(
            &mut source,
            PROFILE,
            "me@icloud.com",
            DEFAULT_LOOKBACK_MONTHS,
        )
        .await
        .unwrap();
    source.logout().await;
    result
}

#[tokio::test]
async fn icloud_statement_is_auto_imported_read_only_and_idempotent() {
    let state = Arc::new(Mutex::new(ImapMockState {
        messages: vec![
            (11, days_ago(20), REMINDER.to_vec()),
            (12, days_ago(10), STATEMENT.to_vec()),
            (13, days_ago(200), REMINDER.to_vec()),
        ],
        ..Default::default()
    }));
    let addr = mock_imap(state.clone()).await;
    let service = service().await;

    let result = imap_sync(&service, addr, IMAP_PASSWORD).await;
    assert_eq!(
        (result.imported, result.skipped, result.scanned),
        (12, 0, 1),
        "标题不含「账单」的通知邮件不列出、不下载"
    );
    assert!(!result.needs_reauth);
    assert_eq!(record_count(&service).await, 12);
    assert_eq!(state.lock().unwrap().mime_requests, vec![12]);
    assert!(
        state
            .lock()
            .unwrap()
            .commands
            .iter()
            .all(|command| !command.contains("BODY[]") || command.contains("BODY.PEEK[]")),
        "只用 BODY.PEEK 下载，不改已读状态"
    );
    assert!(
        state.lock().unwrap().commands.iter().all(|command| {
            ["SELECT", "STORE", "EXPUNGE", "COPY", "MOVE"]
                .iter()
                .all(|verb| !command.contains(verb))
        }),
        "只读打开收件箱，不改动、移动或删除邮件"
    );

    let again = imap_sync(&service, addr, IMAP_PASSWORD).await;
    assert_eq!((again.imported, again.skipped), (0, 0));
    assert_eq!(state.lock().unwrap().mime_requests, vec![12]);
    assert_eq!(record_count(&service).await, 12);
}

#[tokio::test]
async fn icloud_wrong_password_needs_reauth_without_touching_cursor() {
    let state = Arc::new(Mutex::new(ImapMockState {
        messages: vec![(12, days_ago(10), STATEMENT.to_vec())],
        ..Default::default()
    }));
    let addr = mock_imap(state.clone()).await;
    let service = service().await;

    let result = imap_sync(&service, addr, "wrong").await;
    assert!(result.needs_reauth);
    assert_eq!(result.imported, 0);
    assert!(result.state.unwrap().cursor.is_none());
    assert!(state.lock().unwrap().mime_requests.is_empty());
}

#[tokio::test]
async fn icloud_temporary_login_failure_is_retried_not_reauth() {
    let state = Arc::new(Mutex::new(ImapMockState::default()));
    let addr = mock_imap(state.clone()).await;
    let service = service().await;

    let result = imap_sync(&service, addr, IMAP_UNAVAILABLE_PASSWORD).await;
    assert!(!result.needs_reauth);
    assert!(result.error.is_some());
}

/// 真实 iCloud：TLS 握手与登录拒绝映射为 Unauthorized。需要网络，手动运行：
/// `cargo test -p billlens-apple-core icloud_live -- --ignored`
#[tokio::test]
#[ignore]
async fn icloud_live_rejects_invalid_credentials() {
    let mut source =
        ImapSource::icloud("billumi-nonexistent-test@icloud.com", "aaaa-bbbb-cccc-dddd");
    assert_eq!(source.verify().await, Err(MailboxError::Unauthorized));
}
