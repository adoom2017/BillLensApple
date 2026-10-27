//! Microsoft Graph 邮件只读客户端（Hotmail）：列出招行账单邮件、下载原始 MIME。
//! access token 由 Swift 刷新后逐次传入，这里不保存任何凭据。

use super::source::{MailRef, MailSource, MailboxError, STATEMENT_SENDER};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::Deserialize;

pub const GRAPH_BASE_URL: &str = "https://graph.microsoft.com/v1.0";
const PAGE_SIZE: u32 = 25;
/// 防御异常分页：单轮最多跟随的页数。
const MAX_PAGES: usize = 40;

#[derive(Deserialize)]
struct MessagePage {
    value: Vec<MailRef>,
    #[serde(rename = "@odata.nextLink")]
    next_link: Option<String>,
}

#[derive(Clone)]
pub struct GraphClient {
    base_url: String,
    http: reqwest::Client,
}

impl GraphClient {
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("failed to build http client"),
        }
    }

    /// 按接收时间升序列出 `since` 之后（含）的招行账单邮件，跟随分页。
    /// Graph 要求 `$orderby` 的属性在 `$filter` 中最先出现。
    pub async fn list_statement_messages(
        &self,
        access_token: &str,
        since: DateTime<Utc>,
    ) -> Result<Vec<MailRef>, MailboxError> {
        let filter = format!(
            "receivedDateTime ge {} and from/emailAddress/address eq '{STATEMENT_SENDER}'",
            since.to_rfc3339_opts(SecondsFormat::Secs, true)
        );
        let mut request = self
            .http
            .get(format!("{}/me/messages", self.base_url))
            .query(&[
                ("$filter", filter.as_str()),
                ("$orderby", "receivedDateTime asc"),
                ("$select", "id,receivedDateTime"),
                ("$top", &PAGE_SIZE.to_string()),
            ]);
        let mut messages = Vec::new();
        for _ in 0..MAX_PAGES {
            let page: MessagePage = self
                .send(request, access_token)
                .await?
                .json()
                .await
                .map_err(|error| MailboxError::Decode(error.to_string()))?;
            messages.extend(page.value);
            let Some(next) = page.next_link else {
                return Ok(messages);
            };
            // 令牌只发往同一个 Graph 服务，拒绝跟随指向其他主机的分页链接。
            // 前缀含 `/`，防止 `https://graph.microsoft.com/v1.0.evil.example` 之类的主机绕过。
            if !next.starts_with(&format!("{}/", self.base_url)) {
                return Err(MailboxError::Decode("分页链接指向未知主机".into()));
            }
            request = self.http.get(next);
        }
        Err(MailboxError::Decode("分页超过上限".into()))
    }

    pub async fn message_mime(
        &self,
        access_token: &str,
        message_id: &str,
    ) -> Result<Vec<u8>, MailboxError> {
        let mut url = reqwest::Url::parse(&format!("{}/me/messages/", self.base_url))
            .map_err(|error| MailboxError::Decode(error.to_string()))?;
        url.path_segments_mut()
            .map_err(|_| MailboxError::Decode("invalid graph base url".into()))?
            .pop_if_empty()
            .push(message_id)
            .push("$value");
        let bytes = self
            .send(self.http.get(url), access_token)
            .await?
            .bytes()
            .await
            .map_err(|error| MailboxError::Network(error.to_string()))?;
        Ok(bytes.to_vec())
    }

    async fn send(
        &self,
        request: reqwest::RequestBuilder,
        access_token: &str,
    ) -> Result<reqwest::Response, MailboxError> {
        let response = request
            .bearer_auth(access_token)
            .send()
            .await
            .map_err(|error| MailboxError::Network(error.without_url().to_string()))?;
        match response.status().as_u16() {
            200..=299 => Ok(response),
            401 => Err(MailboxError::Unauthorized),
            429 | 503 => Err(MailboxError::Throttled),
            status => Err(MailboxError::Http(status)),
        }
    }
}

/// 一次同步内的 Graph 来源：客户端 + 本轮的 access token。
pub struct GraphSource<'a> {
    pub client: &'a GraphClient,
    pub access_token: &'a str,
}

impl MailSource for GraphSource<'_> {
    async fn list_statement_messages(
        &mut self,
        since: DateTime<Utc>,
    ) -> Result<Vec<MailRef>, MailboxError> {
        self.client
            .list_statement_messages(self.access_token, since)
            .await
    }

    async fn message_mime(&mut self, id: &str) -> Result<Vec<u8>, MailboxError> {
        self.client.message_mime(self.access_token, id).await
    }
}
