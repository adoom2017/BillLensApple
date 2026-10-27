//! iCloud 邮件只读 IMAP 客户端：登录 → `EXAMINE INBOX`（只读打开）→ 按发件人搜索 → `BODY.PEEK[]` 下载。
//! 不改已读状态、不移动或删除邮件。App 专用密码由 Swift 逐次传入，这里不保存、不写日志。

use super::source::{MailRef, MailSource, MailboxError, STATEMENT_SENDER};
use async_imap::{Client, Session, error::Error as ImapError};
use chrono::{DateTime, Utc};
use futures_util::TryStreamExt;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use tokio_rustls::rustls::{ClientConfig, RootCertStore, crypto::ring, pki_types::ServerName};

pub const ICLOUD_IMAP_HOST: &str = "imap.mail.me.com";
pub const ICLOUD_IMAP_PORT: u16 = 993;
const MAILBOX: &str = "INBOX";
/// 每一步网络操作的超时。
const STEP_TIMEOUT: Duration = Duration::from_secs(60);
/// 下载整封邮件的超时：月度账单带内嵌图片，可达 1 MB，iCloud IMAP 在国内较慢。
const MIME_TIMEOUT: Duration = Duration::from_secs(300);
/// 每次取信封的 UID 数，避免一次请求过大而超时。
const ENVELOPE_BATCH: usize = 100;
/// 招行每天还会发「每日信用管家」等通知：只下载标题含此关键词的邮件。
const STATEMENT_SUBJECT_KEYWORD: &str = "账单";

trait ImapStream: AsyncRead + AsyncWrite + Unpin + std::fmt::Debug + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + std::fmt::Debug + Send> ImapStream for T {}

type ImapSession = Session<Box<dyn ImapStream>>;

enum Target {
    Tls {
        host: String,
        port: u16,
    },
    /// 测试用：本地明文模拟服务器。
    #[cfg(test)]
    Plain(std::net::SocketAddr),
}

/// 一次同步内的 IMAP 来源。首次使用时才连接，连接失败（含密码错误）按普通同步错误处理。
pub struct ImapSource {
    target: Target,
    username: String,
    password: String,
    connection: Option<(ImapSession, u32)>,
}

impl ImapSource {
    pub fn icloud(username: &str, password: &str) -> Self {
        Self {
            target: Target::Tls {
                host: ICLOUD_IMAP_HOST.to_string(),
                port: ICLOUD_IMAP_PORT,
            },
            username: username.trim().to_string(),
            password: password.trim().to_string(),
            connection: None,
        }
    }

    #[cfg(test)]
    pub(crate) fn plain(addr: std::net::SocketAddr, username: &str, password: &str) -> Self {
        Self {
            target: Target::Plain(addr),
            username: username.to_string(),
            password: password.to_string(),
            connection: None,
        }
    }

    /// 只校验能否登录并打开收件箱。
    pub async fn verify(&mut self) -> Result<(), MailboxError> {
        self.connection().await.map(|_| ())
    }

    pub async fn logout(&mut self) {
        if let Some((mut session, _)) = self.connection.take() {
            let _ = step(session.logout()).await;
        }
    }

    async fn connection(&mut self) -> Result<&mut (ImapSession, u32), MailboxError> {
        if self.connection.is_none() {
            let stream = self.open_stream().await?;
            self.connection = Some(self.login(stream).await?);
        }
        Ok(self.connection.as_mut().expect("connection just opened"))
    }

    async fn open_stream(&self) -> Result<Box<dyn ImapStream>, MailboxError> {
        match &self.target {
            Target::Tls { host, port } => {
                let tcp = step(TcpStream::connect((host.as_str(), *port)))
                    .await?
                    .map_err(|error| MailboxError::Network(error.kind().to_string()))?;
                let mut roots = RootCertStore::empty();
                roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
                let config =
                    ClientConfig::builder_with_provider(Arc::new(ring::default_provider()))
                        .with_safe_default_protocol_versions()
                        .map_err(|error| MailboxError::Network(error.to_string()))?
                        .with_root_certificates(roots)
                        .with_no_client_auth();
                let name = ServerName::try_from(host.clone())
                    .map_err(|error| MailboxError::Network(error.to_string()))?;
                let tls = step(TlsConnector::from(Arc::new(config)).connect(name, tcp))
                    .await?
                    .map_err(|error| MailboxError::Network(error.kind().to_string()))?;
                Ok(Box::new(tls))
            }
            #[cfg(test)]
            Target::Plain(addr) => {
                let tcp = step(TcpStream::connect(addr))
                    .await?
                    .map_err(|error| MailboxError::Network(error.kind().to_string()))?;
                Ok(Box::new(tcp))
            }
        }
    }

    async fn login(&self, stream: Box<dyn ImapStream>) -> Result<(ImapSession, u32), MailboxError> {
        let mut client = Client::new(stream);
        step(client.read_response())
            .await?
            .map_err(|error| MailboxError::Network(error.kind().to_string()))?
            .ok_or_else(|| MailboxError::Network("邮箱服务器没有响应".into()))?;
        let mut session = match step(client.login(&self.username, &self.password)).await? {
            Ok(session) => session,
            // RFC 5530 `[UNAVAILABLE]`：服务器临时故障，不是密码问题，下次重试。
            Err((ImapError::No(text), _)) if text.contains("[UNAVAILABLE]") => {
                return Err(MailboxError::Throttled);
            }
            Err((ImapError::No(_) | ImapError::Bad(_), _)) => {
                return Err(MailboxError::Unauthorized);
            }
            Err((error, _)) => return Err(map_error(error)),
        };
        // EXAMINE 以只读方式打开收件箱：服务器不会改动任何标志（含 \\Recent）。
        let mailbox = step(session.examine(MAILBOX)).await?.map_err(map_error)?;
        Ok((session, mailbox.uid_validity.unwrap_or(0)))
    }
}

impl MailSource for ImapSource {
    async fn list_statement_messages(
        &mut self,
        since: DateTime<Utc>,
    ) -> Result<Vec<MailRef>, MailboxError> {
        let (session, uid_validity) = self.connection().await?;
        let uid_validity = *uid_validity;
        // SEARCH SINCE 只精确到日，且按服务器时区的日期比较：提前一天搜索，再按 INTERNALDATE 精确过滤。
        let search_day = since - chrono::Duration::days(1);
        let query = format!(
            "SINCE {} FROM \"{STATEMENT_SENDER}\"",
            search_day.format("%d-%b-%Y")
        );
        let mut uids: Vec<u32> = step(session.uid_search(query))
            .await?
            .map_err(map_error)?
            .into_iter()
            .collect();
        if uids.is_empty() {
            return Ok(Vec::new());
        }
        uids.sort_unstable();
        // 只取信封（含标题），不下载正文；标题不像账单的通知邮件直接略过。
        let mut messages = Vec::new();
        for chunk in uids.chunks(ENVELOPE_BATCH) {
            let set = chunk
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join(",");
            let fetches = step(async {
                session
                    .uid_fetch(set, "(UID INTERNALDATE ENVELOPE)")
                    .await?
                    .try_collect::<Vec<_>>()
                    .await
            })
            .await?
            .map_err(map_error)?;
            messages.extend(fetches.iter().filter_map(|fetch| {
                let subject = fetch.envelope()?.subject.as_deref().map(decode_subject)?;
                if !subject.contains(STATEMENT_SUBJECT_KEYWORD) {
                    return None;
                }
                let received_at = fetch.internal_date()?.with_timezone(&Utc);
                let uid = fetch.uid?;
                (received_at >= since).then(|| MailRef {
                    id: format!("icloud:{uid_validity}:{uid}"),
                    received_at,
                })
            }));
        }
        messages.sort_by(|a, b| a.received_at.cmp(&b.received_at).then(a.id.cmp(&b.id)));
        Ok(messages)
    }

    async fn message_mime(&mut self, id: &str) -> Result<Vec<u8>, MailboxError> {
        let (session, uid_validity) = self.connection().await?;
        let uid = id
            .strip_prefix(&format!("icloud:{uid_validity}:"))
            .and_then(|uid| uid.parse::<u32>().ok())
            .ok_or_else(|| MailboxError::Decode("邮件编号与当前收件箱不匹配".into()))?;
        let fetches = within(MIME_TIMEOUT, async {
            session
                .uid_fetch(uid.to_string(), "BODY.PEEK[]")
                .await?
                .try_collect::<Vec<_>>()
                .await
        })
        .await?
        .map_err(map_error)?;
        fetches
            .iter()
            .find_map(|fetch| fetch.body().map(<[u8]>::to_vec))
            .ok_or_else(|| MailboxError::Decode("邮件已不存在".into()))
    }
}

async fn step<F: Future>(future: F) -> Result<F::Output, MailboxError> {
    within(STEP_TIMEOUT, future).await
}

async fn within<F: Future>(limit: Duration, future: F) -> Result<F::Output, MailboxError> {
    tokio::time::timeout(limit, future)
        .await
        .map_err(|_| MailboxError::Network("连接邮箱服务器超时".into()))
}

/// 信封里的标题是原始的 RFC 2047 编码，借 mail-parser 解码。
fn decode_subject(raw: &[u8]) -> String {
    let mut header = b"Subject: ".to_vec();
    header.extend_from_slice(raw);
    header.extend_from_slice(b"\r\n\r\n");
    mail_parser::MessageParser::default()
        .parse(&header)
        .and_then(|message| message.subject().map(str::to_string))
        .unwrap_or_default()
}

fn map_error(error: ImapError) -> MailboxError {
    match error {
        ImapError::Io(error) => MailboxError::Network(error.kind().to_string()),
        ImapError::ConnectionLost => MailboxError::Network("连接已断开".into()),
        ImapError::No(_) | ImapError::Bad(_) => MailboxError::Decode("邮箱服务器拒绝了请求".into()),
        // 解析错误可能带原始响应字节（邮件内容），不写入 last_error。
        ImapError::Parse(_) => MailboxError::Decode("邮箱服务器响应格式异常".into()),
        other => MailboxError::Decode(other.to_string()),
    }
}
