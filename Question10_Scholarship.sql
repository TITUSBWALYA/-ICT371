-- ============================================================
-- Question 10: Scholarship Application Assessment - 50 marks
-- Qualify ONLY when: age 18-25 inclusive, income <= K3,000, mark >= 70
-- Statuses: PENDING, APPROVED, REJECTED
-- ============================================================
DROP DATABASE IF EXISTS scholarship_db;
CREATE DATABASE scholarship_db;
USE scholarship_db;

-- (a) Tables
CREATE TABLE students (
    student_id INT PRIMARY KEY AUTO_INCREMENT,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id INT PRIMARY KEY AUTO_INCREMENT,
    student_id INT NOT NULL,
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income DECIMAL(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark DECIMAL(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    FOREIGN KEY (student_id) REFERENCES students(student_id)
);

CREATE TABLE decision_audit (
    audit_id INT PRIMARY KEY AUTO_INCREMENT,
    application_id INT NOT NULL,
    old_status VARCHAR(20) NOT NULL,
    new_status VARCHAR(20) NOT NULL,
    changed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (application_id) REFERENCES applications(application_id)
);

-- Seed 3 students
INSERT INTO students (student_number, full_name) VALUES
('STU001', 'Titus Bwalya'),
('STU002', 'Grace Mwale'),
('STU003', 'Peter Phiri');

-- (b) Function: fn_scholarship_eligible(p_age, p_income, p_mark)
DELIMITER $$
CREATE FUNCTION fn_scholarship_eligible(
    p_age INT,
    p_income DECIMAL(10,2),
    p_mark DECIMAL(5,2)
)
RETURNS BOOLEAN
DETERMINISTIC
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Eligibility inputs cannot be NULL';
    END IF;
    IF p_age <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Age must be positive';
    END IF;
    IF p_income < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Income cannot be negative';
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Mark must be between 0 and 100';
    END IF;
    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END$$
DELIMITER ;

-- (c) Procedure: pr_assess_application(p_application_id)
DELIMITER $$
CREATE PROCEDURE pr_assess_application(IN p_application_id INT)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_age INT;
    DECLARE v_income DECIMAL(10,2);
    DECLARE v_mark DECIMAL(5,2);
    DECLARE v_new VARCHAR(20);
    SELECT status, age_at_application, monthly_income, average_mark
    INTO v_status, v_age, v_income, v_mark
    FROM applications WHERE application_id = p_application_id;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown application';
    END IF;
    IF v_status <> 'PENDING' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Application already assessed';
    END IF;
    IF fn_scholarship_eligible(v_age, v_income, v_mark) THEN
        SET v_new = 'APPROVED';
    ELSE
        SET v_new = 'REJECTED';
    END IF;
    UPDATE applications SET status = v_new
    WHERE application_id = p_application_id;
END$$
DELIMITER ;

-- (d) Trigger: AFTER UPDATE - record ACTUAL status changes only
DELIMITER $$
CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, NOW());
    END IF;
END$$
DELIMITER ;

-- (a continued) Seed 6 PENDING applications
-- Qualifying, non-qualifying AND boundary cases, across 3 students
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
(1, 20, 2500.00, 85.00, '2026-11-20', 'PENDING'), -- qualifies -> APPROVED
(1, 26, 2500.00, 85.00, '2026-11-20', 'PENDING'), -- age 26 fails -> REJECTED
(2, 18, 3000.00, 70.00, '2026-11-21', 'PENDING'), -- boundary 18 / 3000 / 70 -> APPROVED
(2, 25, 3000.00, 70.00, '2026-11-21', 'PENDING'), -- boundary 25 / 3000 / 70 -> APPROVED
(3, 22, 3500.00, 90.00, '2026-11-22', 'PENDING'), -- income over 3000 -> REJECTED
(3, 19, 2000.00, 69.00, '2026-11-22', 'PENDING'); -- mark 69 < 70 -> REJECTED

-- Assess 2 individually to show procedure + trigger
CALL pr_assess_application(1);
CALL pr_assess_application(2);
SELECT * FROM decision_audit ORDER BY audit_id;

-- Invalid examples (should fail):
-- CALL pr_assess_application(1); -- already assessed
-- CALL pr_assess_application(999); -- unknown

-- (e) View: v_approved_applicants - APPROVED only, NO household income
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- (f) Index: applications searched by status within submitted_on date range
-- Justification: equality on status first, then range on submitted_on.
-- Composite (status, submitted_on) seeks straight to that status in that date range.
CREATE INDEX idx_applications_status_date ON applications (status, submitted_on);

EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN '2026-11-20' AND '2026-11-22';

-- (g) Scheduled job: pr_assess_pending() - FOR loop over PENDING only
-- MySQL uses a CURSOR loop. Calls pr_assess_application for each PENDING row.
DELIMITER $$
CREATE PROCEDURE pr_assess_pending()
BEGIN
    DECLARE done INT DEFAULT FALSE;
    DECLARE v_id INT;
    DECLARE cur CURSOR FOR
        SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_id;
        IF done THEN
            LEAVE read_loop;
        END IF;
        CALL pr_assess_application(v_id);
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

-- Assess the rest: rerun must NOT reassess completed or duplicate audit entries
CALL pr_assess_pending();
CALL pr_assess_pending(); -- second run does nothing, no duplicate audits
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;
SELECT * FROM v_approved_applicants;

-- Schedule every Monday at 08:00 (next Monday = 2026-11-30)
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_assess_pending;
DELIMITER $$
CREATE EVENT evt_assess_pending
ON SCHEDULE EVERY 1 WEEK STARTS '2026-11-30 08:00:00'
DO
BEGIN
    CALL pr_assess_pending();
END$$
DELIMITER ;
