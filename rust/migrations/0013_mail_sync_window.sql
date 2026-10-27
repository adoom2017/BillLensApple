-- 已完整覆盖的同步起点。用户把「同步最近 N 个月」调大到早于此时间时，清空游标从新的起点重扫（已处理邮件按 id 跳过）。
ALTER TABLE mail_sync_state ADD COLUMN synced_from TEXT;
