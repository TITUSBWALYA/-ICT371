-- ============================================================
-- Question 6: Monthly Payroll Processing - 50 marks
-- gross = basic + allowance, net = gross - deduction
-- Re-processing a month must leave existing rows UNCHANGED.
-- ============================================================
DROP DATABASE IF EXISTS payroll_db;
CREATE DATABASE payroll_db;
USE payroll_db;

-- (a) Tables
CREATE TABLE employees (
    employee_id INT PRIMARY KEY AUTO_INCREMENT,
    full_name VARCHAR(100) NOT NULL,
    basic_salary DECIMAL(10,2) NOT NULL CHECK (basic_salary >= 0),
    allowance DECIMAL(10,2) NOT NULL CHECK (allowance >= 0),
    deduction DECIMAL(10,2) NOT NULL CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id INT PRIMARY KEY AUTO_INCREMENT,
    employee_id INT NOT NULL,
    pay_month DATE NOT NULL,
    gross_pay DECIMAL(12,2) NOT NULL,
    net_pay DECIMAL(12,2) NOT NULL,
    UNIQUE KEY uq_payroll_employee_month (employee_id, pay_month),
    FOREIGN KEY (employee_id) REFERENCES employees(employee_id)
);

CREATE TABLE salary_audit (
    audit_id INT PRIMARY KEY AUTO_INCREMENT,
    employee_id INT NOT NULL,
    old_salary DECIMAL(10,2) NOT NULL,
    new_salary DECIMAL(10,2) NOT NULL,
    changed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (employee_id) REFERENCES employees(employee_id)
);

-- Seed: active + inactive employees
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
('Titus Bwalya', 8000.00, 1000.00, 500.00, TRUE),
('Grace Mwale', 6500.00, 800.00, 400.00, TRUE),
('Peter Phiri', 5000.00, 500.00, 300.00, TRUE),
('Emma Chanda', 7000.00, 0.00, 200.00, TRUE),
('Frank Tembo', 6000.00, 600.00, 300.00, FALSE); -- inactive, must NOT be paid

-- (b) Function: fn_net_pay(p_employee_id)
DELIMITER $$
CREATE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS DECIMAL(12,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_basic DECIMAL(10,2);
    DECLARE v_allow DECIMAL(10,2);
    DECLARE v_ded DECIMAL(10,2);
    DECLARE v_net DECIMAL(12,2);
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
    FROM employees WHERE employee_id = p_employee_id;
    IF v_basic IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown employee';
    END IF;
    SET v_net = (v_basic + v_allow) - v_ded;
    IF v_net < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Negative computed net pay';
    END IF;
    RETURN v_net;
END$$
DELIMITER ;

-- (c) Procedure: pr_process_payroll(p_month) - FOR loop over ACTIVE employees
-- MySQL uses a CURSOR loop. Require month-start date.
-- Insert missing rows only; leave existing row unchanged.
-- Any invalid calculation fails the WHOLE call (ROLLBACK).
DELIMITER $$
CREATE PROCEDURE pr_process_payroll(IN p_month DATE)
BEGIN
    DECLARE done INT DEFAULT FALSE;
    DECLARE v_emp INT;
    DECLARE v_basic DECIMAL(10,2);
    DECLARE v_allow DECIMAL(10,2);
    DECLARE v_gross DECIMAL(12,2);
    DECLARE v_net DECIMAL(12,2);
    DECLARE cur CURSOR FOR
        SELECT employee_id, basic_salary, allowance FROM employees WHERE active = TRUE ORDER BY employee_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;
    IF p_month IS NULL OR DAY(p_month) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'p_month must be the first date of a month (e.g. 2026-11-01)';
    END IF;
    START TRANSACTION;
    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_emp, v_basic, v_allow;
        IF done THEN
            LEAVE read_loop;
        END IF;
        -- This calls fn_net_pay, which SIGNALS if net is negative -> whole call rolls back
        SET v_net = fn_net_pay(v_emp);
        SET v_gross = v_basic + v_allow;
        -- Leave existing row unchanged on re-run
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (v_emp, p_month, v_gross, v_net)
        ON DUPLICATE KEY UPDATE payroll_id = payroll_id;
    END LOOP;
    CLOSE cur;
    COMMIT;
END$$
DELIMITER ;

-- (d) Trigger: AFTER UPDATE, log ONLY actual basic_salary changes
DELIMITER $$
CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
BEGIN
    IF OLD.basic_salary <> NEW.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, NOW());
    END IF;
END$$
DELIMITER ;

-- (a continued) Process at least two payroll months
CALL pr_process_payroll('2026-10-01');
CALL pr_process_payroll('2026-11-01');

-- Re-processing must NOT change existing rows
CALL pr_process_payroll('2026-11-01');
SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- Trigger test: real change logs, unchanged salary does NOT log
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1; -- logs
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1; -- no log, same value
SELECT * FROM salary_audit ORDER BY audit_id;

-- Later, employee 2 becomes inactive - historical payroll must still show in view
UPDATE employees SET active = FALSE WHERE employee_id = 2;

-- (e) View: v_payroll_report - names + month + gross + net, incl. now-inactive
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index: report filtered by pay_month across all employees
-- Justification: query filters by pay_month only, across all employees.
-- Existing unique index is (employee_id, pay_month) - pay_month is SECOND there,
-- so it cannot seek by pay_month alone. A separate (pay_month) index can.
-- This does NOT duplicate the unique index because column order is different.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

EXPLAIN SELECT * FROM payroll WHERE pay_month = '2026-11-01';

-- (g) Scheduled job: 02:00 on 1st of each month, for previous month
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_process_payroll_monthly;
DELIMITER $$
CREATE EVENT evt_process_payroll_monthly
ON SCHEDULE EVERY 1 MONTH STARTS '2026-12-01 02:00:00'
DO
BEGIN
    CALL pr_process_payroll(DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL 1 MONTH));
END$$
DELIMITER ;

-- How to inspect the job and its run history:
SHOW EVENTS FROM payroll_db;
SELECT EVENT_SCHEMA, EVENT_NAME, EVENT_DEFINITION, STATUS, LAST_EXECUTED
FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'payroll_db';
-- MySQL has no built-in event run-history table, so history = the payroll rows created:
SELECT pay_month, COUNT(*) AS employees_paid, SUM(net_pay) AS total_net
FROM payroll GROUP BY pay_month ORDER BY pay_month;
