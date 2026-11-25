-- ============================================================
-- Question 7: Water Meter Readings and Billing - 50 marks
-- Tariff: first 10 units @ K5 each, units above 10 @ K8 each.
-- Zero consumption = K0.
-- ============================================================
DROP DATABASE IF EXISTS water_db;
CREATE DATABASE water_db;
USE water_db;

-- (a) Tables
CREATE TABLE customers (
    customer_id INT PRIMARY KEY AUTO_INCREMENT,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id INT PRIMARY KEY AUTO_INCREMENT,
    customer_id INT NOT NULL,
    reading_month DATE NOT NULL,
    previous_reading DECIMAL(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading DECIMAL(10,2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE KEY uq_readings_customer_month (customer_id, reading_month),
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

CREATE TABLE bills (
    bill_id INT PRIMARY KEY AUTO_INCREMENT,
    reading_id INT NOT NULL UNIQUE,
    charge DECIMAL(10,2) NOT NULL CHECK (charge >= 0),
    amount_paid DECIMAL(10,2) NOT NULL DEFAULT 0,
    due_on DATE NOT NULL,
    CHECK (amount_paid >= 0 AND amount_paid <= charge),
    FOREIGN KEY (reading_id) REFERENCES readings(reading_id)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due DECIMAL(12,2) NOT NULL DEFAULT 0
);

-- Seed 3 customers
INSERT INTO customers (full_name) VALUES
('Titus Bwalya'), ('Grace Mwale'), ('Peter Phiri');

-- (b) Function: fn_water_charge(p_units)
DELIMITER $$
CREATE FUNCTION fn_water_charge(p_units DECIMAL(10,2))
RETURNS DECIMAL(10,2)
DETERMINISTIC
BEGIN
    IF p_units IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Consumption cannot be NULL';
    END IF;
    IF p_units < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Consumption cannot be negative';
    END IF;
    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5.00, 2);
    ELSE
        RETURN ROUND(10 * 5.00 + (p_units - 10) * 8.00, 2);
    END IF;
END$$
DELIMITER ;

-- (c) Procedure: pr_generate_bill(p_reading_id, p_due_on)
DELIMITER $$
CREATE PROCEDURE pr_generate_bill(
    IN p_reading_id INT,
    IN p_due_on DATE
)
BEGIN
    DECLARE v_prev DECIMAL(10,2);
    DECLARE v_curr DECIMAL(10,2);
    DECLARE v_units DECIMAL(10,2);
    DECLARE v_exists INT;
    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF v_prev IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown reading';
    END IF;
    IF p_due_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid due_on date';
    END IF;
    SELECT COUNT(*) INTO v_exists FROM bills WHERE reading_id = p_reading_id;
    IF v_exists > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reading already has a bill';
    END IF;
    SET v_units = v_curr - v_prev;
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END$$
DELIMITER ;

-- (d) Trigger: BEFORE INSERT OR UPDATE on readings - reject current < previous
-- MySQL needs two triggers with the same logic. Rejected row is NOT stored.
DELIMITER $$
CREATE TRIGGER trg_readings_check_ins
BEFORE INSERT ON readings
FOR EACH ROW
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'current_reading cannot be below previous_reading';
    END IF;
END$$

CREATE TRIGGER trg_readings_check_upd
BEFORE UPDATE ON readings
FOR EACH ROW
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'current_reading cannot be below previous_reading';
    END IF;
END$$
DELIMITER ;

-- (a continued) Seed 6 readings - after trigger is installed
-- 0 units, exactly 10 units, above 10 units all covered
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
(1, '2026-10-01', 100, 100), -- 0 units -> K0
(1, '2026-11-01', 100, 110), -- 10 units -> K50
(2, '2026-10-01', 50, 65),   -- 15 units -> K90 (50 + 40)
(2, '2026-11-01', 65, 70),   -- 5 units -> K25
(3, '2026-10-01', 0, 20),    -- 20 units -> K130 (50 + 80)
(3, '2026-11-01', 20, 20);   -- 0 units -> K0

-- Invalid reading (should fail, not stored):
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES (1, '2026-12-01', 110, 100);

-- Generate bills through procedure (amount_paid = 0)
CALL pr_generate_bill(1, DATE_SUB(CURDATE(), INTERVAL 5 DAY));  -- overdue
CALL pr_generate_bill(2, DATE_ADD(CURDATE(), INTERVAL 10 DAY)); -- not yet due
CALL pr_generate_bill(3, DATE_SUB(CURDATE(), INTERVAL 3 DAY));  -- overdue
CALL pr_generate_bill(4, DATE_ADD(CURDATE(), INTERVAL 10 DAY)); -- not yet due
CALL pr_generate_bill(5, DATE_SUB(CURDATE(), INTERVAL 1 DAY));  -- overdue
CALL pr_generate_bill(6, DATE_ADD(CURDATE(), INTERVAL 10 DAY)); -- not yet due

-- Invalid: already has a bill
-- CALL pr_generate_bill(1, DATE_ADD(CURDATE(), INTERVAL 10 DAY));

-- Partial payment example: bill 3 was K90, pay K20, K70 still outstanding
UPDATE bills SET amount_paid = 20.00 WHERE bill_id = 3;

SELECT * FROM bills ORDER BY bill_id;

-- (e) View: v_overdue_bills - due before today and not fully paid
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on,
       (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) Index: date-based searches for overdue bills
-- Justification: overdue query filters by due_on < CURRENT_DATE first,
-- then checks amount_paid < charge. Index on (due_on) lets MySQL seek
-- only past-due rows instead of scanning all bills.
CREATE INDEX idx_bills_due_on ON bills (due_on);

EXPLAIN SELECT * FROM bills
WHERE due_on < CURRENT_DATE AND amount_paid < charge;

-- (g) Scheduled job: pr_refresh_receivables() - today's total unpaid balances
DELIMITER $$
CREATE PROCEDURE pr_refresh_receivables()
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills WHERE amount_paid < charge
    ON DUPLICATE KEY UPDATE total_due = VALUES(total_due);
END$$
DELIMITER ;

-- Test: run twice, second run must replace, not double
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;

-- Schedule daily at 00:30
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_refresh_receivables;
DELIMITER $$
CREATE EVENT evt_refresh_receivables
ON SCHEDULE EVERY 1 DAY STARTS '2026-11-26 00:30:00'
DO
BEGIN
    CALL pr_refresh_receivables();
END$$
DELIMITER ;
