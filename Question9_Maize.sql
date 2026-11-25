-- ============================================================
-- Question 9: Farmer Cooperative Maize Deliveries - 50 marks
-- Prices: Grade A = K5/kg, B = K4/kg, C = K3/kg
-- Delivery values must be calculated consistently, even for direct SQL.
-- ============================================================
DROP DATABASE IF EXISTS maize_db;
CREATE DATABASE maize_db;
USE maize_db;

-- (a) Tables
CREATE TABLE farmers (
    farmer_id INT PRIMARY KEY AUTO_INCREMENT,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id INT PRIMARY KEY AUTO_INCREMENT,
    farmer_id INT NOT NULL,
    grade CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg DECIMAL(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate DECIMAL(10,2) NOT NULL DEFAULT 0,
    total_value DECIMAL(12,2) NOT NULL DEFAULT 0,
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE,
    FOREIGN KEY (farmer_id) REFERENCES farmers(farmer_id)
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight DECIMAL(12,2) NOT NULL DEFAULT 0,
    total_value DECIMAL(12,2) NOT NULL DEFAULT 0
);

-- Seed 3 farmers
INSERT INTO farmers (farmer_number, full_name) VALUES
('F001', 'Titus Bwalya'),
('F002', 'Grace Mwale'),
('F003', 'Peter Phiri');

-- (b) Function: fn_maize_rate(p_grade)
DELIMITER $$
CREATE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS DECIMAL(10,2)
DETERMINISTIC
BEGIN
    IF p_grade IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Grade cannot be NULL';
    END IF;
    IF p_grade = 'A' THEN
        RETURN 5.00;
    ELSEIF p_grade = 'B' THEN
        RETURN 4.00;
    ELSEIF p_grade = 'C' THEN
        RETURN 3.00;
    ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unsupported grade: use A, B or C';
    END IF;
END$$
DELIMITER ;

-- (c) Procedure: pr_receive_delivery(p_farmer_id, p_grade, p_weight, p_date)
-- Inserts basic fields with is_paid FALSE. Trigger supplies unit_rate + total_value.
DELIMITER $$
CREATE PROCEDURE pr_receive_delivery(
    IN p_farmer_id INT,
    IN p_grade CHAR(1),
    IN p_weight DECIMAL(10,2),
    IN p_date DATE
)
BEGIN
    DECLARE v_exists INT;
    SELECT COUNT(*) INTO v_exists FROM farmers WHERE farmer_id = p_farmer_id;
    IF v_exists = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown farmer';
    END IF;
    IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid grade: use A, B or C';
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Weight must be positive';
    END IF;
    IF p_date IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid delivery date';
    END IF;
    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, 0, 0, p_date, FALSE);
END$$
DELIMITER ;

-- (d) Trigger: BEFORE INSERT OR UPDATE - reject non-positive weight,
-- call fn_maize_rate, set NEW.unit_rate and NEW.total_value
-- MySQL needs two triggers with the same logic. Direct SQL follows same rule.
DELIMITER $$
CREATE TRIGGER trg_deliveries_price_ins
BEFORE INSERT ON deliveries
FOR EACH ROW
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Weight must be positive';
    END IF;
    SET NEW.unit_rate = fn_maize_rate(NEW.grade);
    SET NEW.total_value = ROUND(NEW.weight_kg * NEW.unit_rate, 2);
END$$

CREATE TRIGGER trg_deliveries_price_upd
BEFORE UPDATE ON deliveries
FOR EACH ROW
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Weight must be positive';
    END IF;
    SET NEW.unit_rate = fn_maize_rate(NEW.grade);
    SET NEW.total_value = ROUND(NEW.weight_kg * NEW.unit_rate, 2);
END$$
DELIMITER ;

-- (a continued) Seed 6 deliveries - all grades, both payment states
-- 5 through procedure, 1 through direct SQL to prove trigger works there too
CALL pr_receive_delivery(1, 'A', 100, '2026-11-20'); -- 100 x 5 = 500
CALL pr_receive_delivery(1, 'B', 50, '2026-11-20');  -- 50 x 4 = 200
CALL pr_receive_delivery(2, 'C', 80, '2026-11-21');  -- 80 x 3 = 240
CALL pr_receive_delivery(2, 'A', 120, '2026-11-21'); -- 120 x 5 = 600
CALL pr_receive_delivery(3, 'B', 60, '2026-11-22');  -- 60 x 4 = 240

-- Direct SQL with DELIBERATELY WRONG rate/value - trigger must correct them to 3 / 120
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'C', 40, 999, 999, '2026-11-22', FALSE);

-- Both payment states: mark 2 deliveries as paid
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (2, 4);

SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid
FROM deliveries ORDER BY delivery_id;

-- Invalid examples (should fail):
-- CALL pr_receive_delivery(1, 'D', 10, '2026-11-23'); -- unsupported grade
-- CALL pr_receive_delivery(1, 'A', 0, '2026-11-23'); -- non-positive weight
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid) VALUES (1, 'A', -5, 0, 0, '2026-11-23', FALSE);

-- (e) View: v_farmer_amount_due - every farmer, unpaid = 0 if none unpaid
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(CASE WHEN d.is_paid = FALSE THEN d.total_value ELSE 0 END), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due;

-- (f) Index: a farmer's deliveries between two dates
-- Justification: equality on farmer_id first, then range on delivered_on.
-- Composite (farmer_id, delivered_on) seeks straight to that farmer's
-- deliveries in that date range instead of scanning all deliveries.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN '2026-11-20' AND '2026-11-22';

-- (g) Scheduled job: pr_refresh_purchases(p_day)
DELIMITER $$
CREATE PROCEDURE pr_refresh_purchases(IN p_day DATE)
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries WHERE delivered_on = p_day
    ON DUPLICATE KEY UPDATE
        total_weight = VALUES(total_weight),
        total_value = VALUES(total_value);
END$$
DELIMITER ;

-- Test: run twice, second run must replace, not add again
CALL pr_refresh_purchases('2026-11-20');
CALL pr_refresh_purchases('2026-11-20');
SELECT * FROM daily_purchases ORDER BY purchase_date;

-- Schedule daily at 01:30 for previous day
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_refresh_purchases;
DELIMITER $$
CREATE EVENT evt_refresh_purchases
ON SCHEDULE EVERY 1 DAY STARTS '2026-11-26 01:30:00'
DO
BEGIN
    CALL pr_refresh_purchases(DATE_SUB(CURDATE(), INTERVAL 1 DAY));
END$$
DELIMITER ;
