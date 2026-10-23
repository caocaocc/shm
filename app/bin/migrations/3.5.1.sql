-- Add opt-in generic prepaid metering and Epay orders.
-- Existing prices, balances, dates and templates are not rewritten.
BEGIN;

-- Before this release a missing billing currency meant RUB. Make that legacy
-- default explicit on upgrades so the new CNY fallback cannot relabel money.
INSERT IGNORE INTO config (`key`, `value`) VALUES ('billing', '{"currency":"RUB"}');
UPDATE config SET `value`=JSON_SET(COALESCE(`value`, JSON_OBJECT()), '$.currency', 'RUB')
WHERE `key`='billing' AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(`value`, '$.currency')), '')='';

-- PREPAID consumption periods. Monetary values are snapshots of paid cash/bonus;
-- this feature never debits the wallet again when usage is reported.
CREATE TABLE IF NOT EXISTS consumption_periods (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    withdraw_id INT NOT NULL,
    user_service_id INT NOT NULL,
    user_id INT NOT NULL,
    service_id INT NOT NULL,
    policy JSON NOT NULL,
    currency VARCHAR(8) NOT NULL,
    starts_at DATETIME NOT NULL,
    ends_at DATETIME NOT NULL,
    starts_epoch BIGINT UNSIGNED NOT NULL,
    ends_epoch BIGINT UNSIGNED NOT NULL COMMENT 'exclusive, original end_date + 1 second',
    timezone VARCHAR(64) NOT NULL,
    paid_cash DECIMAL(10,2) NOT NULL,
    paid_bonus DECIMAL(10,2) NOT NULL,
    refund_allowed TINYINT NOT NULL DEFAULT 1,
    finalized_at DATETIME NULL COMMENT 'trusted adapter cutoff after resources are stopped',
    finalized_epoch BIGINT UNSIGNED NULL,
    closed_at DATETIME NULL,
    closed_epoch BIGINT UNSIGNED NULL,
    refunded_cash DECIMAL(10,2) NOT NULL DEFAULT 0,
    refunded_bonus DECIMAL(10,2) NOT NULL DEFAULT 0,
    exhausted_notified TINYINT NOT NULL DEFAULT 0,
    created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY consumption_withdraw (withdraw_id),
    KEY consumption_service (user_service_id, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS consumption_generations (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    period_id BIGINT UNSIGNED NOT NULL,
    meter VARCHAR(64) COLLATE utf8mb4_bin NOT NULL,
    generation VARCHAR(128) COLLATE utf8mb4_bin NOT NULL,
    baseline DECIMAL(38,12) NOT NULL,
    cumulative DECIMAL(38,12) NOT NULL,
    observed_epoch BIGINT UNSIGNED NOT NULL,
    active TINYINT NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    UNIQUE KEY consumption_generation (period_id, meter, generation)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS consumption_readings (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    period_id BIGINT UNSIGNED NOT NULL,
    meter VARCHAR(64) COLLATE utf8mb4_bin NOT NULL,
    generation VARCHAR(128) COLLATE utf8mb4_bin NOT NULL,
    record_id VARCHAR(128) COLLATE utf8mb4_bin NOT NULL,
    kind VARCHAR(16) NOT NULL,
    cumulative DECIMAL(38,12) NOT NULL,
    source_observed_at DATETIME NULL,
    observed_epoch BIGINT UNSIGNED NOT NULL,
    created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY consumption_reading (period_id, meter, record_id),
    KEY consumption_reading_generation (period_id, meter, generation)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Epay order audit for fresh installations and upgrades.
-- Signing keys remain in mounted runtime secret files, never in this table.
CREATE TABLE IF NOT EXISTS epay_orders (
  out_trade_no varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  user_id int(11) NOT NULL,
  profile varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  protocol varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  pid varchar(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  key_version varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  gateway_id char(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  config_fingerprint char(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  profile_config json NOT NULL,
  amount_cents bigint unsigned NOT NULL,
  currency char(3) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  payment_type varchar(32) CHARACTER SET ascii COLLATE ascii_bin DEFAULT NULL,
  state varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'PENDING',
  trade_no varchar(64) CHARACTER SET ascii COLLATE ascii_bin DEFAULT NULL,
  payment_id int(11) DEFAULT NULL,
  created_at datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  paid_at datetime DEFAULT NULL,
  PRIMARY KEY (out_trade_no),
  UNIQUE KEY epay_gateway_trade (gateway_id,pid,trade_no),
  UNIQUE KEY epay_payment (payment_id),
  KEY epay_user_state (user_id,state,created_at),
  CONSTRAINT epay_order_user FOREIGN KEY (user_id) REFERENCES users(user_id),
  CONSTRAINT epay_order_payment FOREIGN KEY (payment_id) REFERENCES pays_history(id),
  CONSTRAINT epay_currency CHECK (currency = 'CNY'),
  CONSTRAINT epay_positive_amount CHECK (amount_cents > 0 AND amount_cents <= 9999999999),
  CONSTRAINT epay_protocol CHECK (protocol IN ('v2_rsa','v1_md5')),
  CONSTRAINT epay_state CHECK (state IN ('PENDING','PAID'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

COMMIT;
