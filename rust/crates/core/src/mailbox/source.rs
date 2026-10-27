//! 邮件来源抽象：Hotmail（Graph）与 iCloud（IMAP）共用同一套同步编排。

use chrono::{DateTime, Utc};
use serde::Deserialize;

/// 招商银行信用卡电子账单的发件人。
pub const STATEMENT_SENDER: &str = "ccsvc@message.cmbchina.com";

/// 来源中的一封候选邮件。`id` 在同一邮箱内稳定，用于去重。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct MailRef {
    pub id: String,
    #[serde(rename = "receivedDateTime")]
    pub received_at: DateTime<Utc>,
}

pub(crate) trait MailSource {
    /// 按接收时间升序列出 `since` 之后（含）的招行邮件。
    async fn list_statement_messages(
        &mut self,
        since: DateTime<Utc>,
    ) -> Result<Vec<MailRef>, MailboxError>;

    async fn message_mime(&mut self, id: &str) -> Result<Vec<u8>, MailboxError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MailboxError {
    /// 401：令牌失效或授权被撤销，需要重新连接。
    Unauthorized,
    /// 429 / 503：服务端限流，本轮停止，下次触发重试。
    Throttled,
    Http(u16),
    Network(String),
    Decode(String),
}

impl MailboxError {
    /// 写日志用的错误类别：不含响应正文、解析片段等可能带个人信息的内容。
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Unauthorized => "unauthorized",
            Self::Throttled => "throttled",
            Self::Http(_) => "http",
            Self::Network(_) => "network",
            Self::Decode(_) => "decode",
        }
    }
}

impl std::fmt::Display for MailboxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unauthorized => write!(f, "邮箱授权已失效，请重新连接"),
            Self::Throttled => write!(f, "邮箱服务暂时限流，稍后自动重试"),
            Self::Http(status) => write!(f, "邮箱服务返回错误（HTTP {status}）"),
            Self::Network(message) => write!(f, "无法连接邮箱服务：{message}"),
            Self::Decode(message) => write!(f, "邮箱服务响应格式异常：{message}"),
        }
    }
}
