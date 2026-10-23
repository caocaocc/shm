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
