-- ============================================================
-- Question 2: University Fee Payments - 50 marks
-- Credit balances are NOT allowed.
-- ============================================================
DROP DATABASE IF EXISTS fees_db;
CREATE DATABASE fees_db;
USE fees_db;

-- (a) Tables + seed data
CREATE TABLE students (
    student_id INT PRIMARY KEY AUTO_INCREMENT,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL,
    fee_due DECIMAL(10,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id INT PRIMARY KEY AUTO_INCREMENT,
    student_id INT NOT NULL,
    amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL,
    FOREIGN KEY (student_id) REFERENCES students(student_id)
);

CREATE TABLE payment_audit (
    audit_id INT PRIMARY KEY AUTO_INCREMENT,
    payment_id INT NOT NULL,
    student_id INT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    logged_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (payment_id) REFERENCES payments(payment_id),
    FOREIGN KEY (student_id) REFERENCES students(student_id)
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INT NOT NULL DEFAULT 0,
    total_amount DECIMAL(12,2) NOT NULL DEFAULT 0
);

-- 3 students, different balances. Student 3 starts with NO payments.
INSERT INTO students (student_number, full_name, fee_due) VALUES
('STU001', 'Titus Bwalya', 5000.00),
('STU002', 'Grace Mwale', 3000.00),
('STU003', 'Peter Phiri', 4500.00);

-- (b) Function: fn_fee_balance(p_student_id)
DELIMITER $$
CREATE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS DECIMAL(12,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_due DECIMAL(10,2);
    DECLARE v_paid DECIMAL(12,2);
    SELECT fee_due INTO v_due FROM students WHERE student_id = p_student_id;
    IF v_due IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
    RETURN v_due - v_paid;
END$$
DELIMITER ;

-- (c) Procedure: pr_receive_payment(p_student_id, p_amount, p_paid_on)
-- Rejects NULL/zero/negative and payments above outstanding balance.
-- Does NOT change fee_due. Does NOT insert audit - trigger does that.
DELIMITER $$
CREATE PROCEDURE pr_receive_payment(
    IN p_student_id INT,
    IN p_amount DECIMAL(10,2),
    IN p_paid_on DATE
)
BEGIN
    DECLARE v_balance DECIMAL(12,2);
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid amount: must be positive';
    END IF;
    IF p_paid_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid paid_on date';
    END IF;
    SET v_balance = fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds outstanding balance: credit balances not allowed';
    END IF;
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END$$
DELIMITER ;

-- (d) Trigger: AFTER INSERT on payments -> writes audit automatically
DELIMITER $$
CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, NOW());
END$$
DELIMITER ;

-- (a continued) Seed at least 6 payments THROUGH the procedure
CALL pr_receive_payment(1, 1000.00, '2026-11-18');
CALL pr_receive_payment(1, 1500.00, '2026-11-19');
CALL pr_receive_payment(1, 500.00, '2026-11-20');
CALL pr_receive_payment(2, 1000.00, '2026-11-18');
CALL pr_receive_payment(2, 1000.00, '2026-11-19');
CALL pr_receive_payment(2, 500.00, '2026-11-20');
-- STU003 still has no payments here. Add one later to prove trigger works:
CALL pr_receive_payment(3, 2000.00, '2026-11-21');

-- Invalid examples (should fail, leave tables unchanged):
-- CALL pr_receive_payment(1, 0, '2026-11-21'); -- zero
-- CALL pr_receive_payment(1, -100, '2026-11-21'); -- negative
-- CALL pr_receive_payment(1, 999999, '2026-11-21'); -- above balance

-- Check audit was created by trigger, not by procedure
SELECT * FROM payment_audit ORDER BY audit_id;

-- (e) View: v_fee_balances - only students who still owe, settled excluded
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       (s.fee_due - COALESCE(SUM(p.amount), 0)) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING outstanding_balance > 0;

SELECT * FROM v_fee_balances;

-- (f) Index: payments filtered by student_id + paid_on range
-- Justification: equality on student_id first, then range on paid_on.
-- Composite (student_id, paid_on) seeks to that student then scans only its dates.
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

EXPLAIN SELECT * FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN '2026-11-18' AND '2026-11-20';

-- (g) Scheduled job: pr_refresh_collections(p_day)
DELIMITER $$
CREATE PROCEDURE pr_refresh_collections(IN p_day DATE)
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON DUPLICATE KEY UPDATE
        payment_count = VALUES(payment_count),
        total_amount = VALUES(total_amount);
END$$
DELIMITER ;

-- Test: run twice, second run must replace, not double
CALL pr_refresh_collections('2026-11-19');
CALL pr_refresh_collections('2026-11-19');
SELECT * FROM daily_collections ORDER BY collection_date;

-- Schedule daily at 01:00 for previous day
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_refresh_collections;
DELIMITER $$
CREATE EVENT evt_refresh_collections
ON SCHEDULE EVERY 1 DAY STARTS '2026-11-26 01:00:00'
DO
BEGIN
    CALL pr_refresh_collections(DATE_SUB(CURDATE(), INTERVAL 1 DAY));
END$$
DELIMITER ;
