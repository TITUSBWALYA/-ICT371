-- ============================================================
-- Question 3: Library Returns and Overdue Fines - 50 marks
-- Fine = K2 per day after due date. Return on due date = K0.
-- Returned loan stops accumulating fines.
-- ============================================================
DROP DATABASE IF EXISTS library_db;
CREATE DATABASE library_db;
USE library_db;

-- (a) Tables
CREATE TABLE books (
    book_id INT PRIMARY KEY AUTO_INCREMENT,
    title VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id INT PRIMARY KEY AUTO_INCREMENT,
    book_id INT NOT NULL,
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE NULL,
    fine_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
    CHECK (due_on >= borrowed_on),
    FOREIGN KEY (book_id) REFERENCES books(book_id)
);

CREATE TABLE loan_audit (
    audit_id INT PRIMARY KEY AUTO_INCREMENT,
    loan_id INT NOT NULL,
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (loan_id) REFERENCES loans(loan_id)
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0,
    total_fine DECIMAL(12,2) NOT NULL DEFAULT 0
);

-- Seed 3 books
INSERT INTO books (title) VALUES
('Database Systems'),
('Data Structures'),
('Computer Networking');

-- (b) Function: fn_loan_fine(p_loan_id, p_as_of)
-- K2 * overdue days, min 0. Use earlier of p_as_of and returned_on if returned.
DELIMITER $$
CREATE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS DECIMAL(10,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_due DATE;
    DECLARE v_returned DATE;
    DECLARE v_effective DATE;
    DECLARE v_days INT;
    IF p_as_of IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid as_of date';
    END IF;
    SELECT due_on, returned_on INTO v_due, v_returned FROM loans WHERE loan_id = p_loan_id;
    IF v_due IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown loan';
    END IF;
    IF v_returned IS NOT NULL AND v_returned < p_as_of THEN
        SET v_effective = v_returned;
    ELSE
        SET v_effective = p_as_of;
    END IF;
    SET v_days = DATEDIFF(v_effective, v_due);
    IF v_days < 0 THEN
        SET v_days = 0;
    END IF;
    RETURN v_days * 2.00;
END$$
DELIMITER ;

-- (c) Procedure: pr_return_loan(p_loan_id, p_returned_on)
-- Reject unknown / already returned / return before borrowed_on.
-- Store return date + final fine together.
DELIMITER $$
CREATE PROCEDURE pr_return_loan(
    IN p_loan_id INT,
    IN p_returned_on DATE
)
BEGIN
    DECLARE v_borrowed DATE;
    DECLARE v_returned DATE;
    DECLARE v_fine DECIMAL(10,2);
    IF p_returned_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid return date';
    END IF;
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF v_borrowed IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown loan';
    END IF;
    IF v_returned IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan already returned';
    END IF;
    IF p_returned_on < v_borrowed THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Return date cannot be before borrowed_on';
    END IF;
    -- At this point returned_on is still NULL, so fn uses p_returned_on as as_of
    SET v_fine = fn_loan_fine(p_loan_id, p_returned_on);
    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END$$
DELIMITER ;

-- (d) Trigger: AFTER UPDATE, log returned_on changes only when changed
DELIMITER $$
CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
BEGIN
    IF NOT (OLD.returned_on <=> NEW.returned_on) THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, NOW());
    END IF;
END$$
DELIMITER ;

-- (a continued) Seed 6 loans
-- 1 = open overdue, 2 = open not yet due, 3 = open overdue,
-- 4 = on-time return, 5 = late return, 6 = open due soon
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
(1, 'Alice Banda', '2026-11-01', '2026-11-10', NULL, 0),
(2, 'Bob Mwale', '2026-11-20', '2026-11-27', NULL, 0),
(1, 'Carol Zulu', '2026-11-15', '2026-11-22', NULL, 0),
(3, 'David Phiri', '2026-11-10', '2026-11-17', NULL, 0),
(2, 'Emma Chanda', '2026-11-05', '2026-11-12', NULL, 0),
(3, 'Frank Tembo', '2026-11-18', '2026-11-25', NULL, 0);

-- Returns through procedure (creates audit rows via trigger)
CALL pr_return_loan(4, '2026-11-17'); -- on time, fine = 0
CALL pr_return_loan(5, '2026-11-15'); -- 3 days late, fine = 6.00

-- Invalid examples (should fail):
-- CALL pr_return_loan(4, '2026-11-18'); -- already returned
-- CALL pr_return_loan(1, '2026-10-01'); -- before borrowed_on

SELECT * FROM loan_audit ORDER BY audit_id;
SELECT loan_id, borrower_name, due_on, returned_on, fine_amount FROM loans;

-- (e) View: v_overdue_loans - unreturned and due before today
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title AS book_title, l.borrower_name,
       l.due_on, fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index: search for a given book's unreturned loans
-- Justification: equality on book_id first, then filter returned_on IS NULL.
-- Composite (book_id, returned_on) seeks straight to that book's open loans.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id, returned_on);

EXPLAIN SELECT * FROM loans
WHERE book_id = 1 AND returned_on IS NULL;

-- (g) Scheduled job: pr_refresh_overdue(p_as_of)
DELIMITER $$
CREATE PROCEDURE pr_refresh_overdue(IN p_as_of DATE)
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND due_on < p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
    ON DUPLICATE KEY UPDATE
        overdue_count = VALUES(overdue_count),
        total_fine = VALUES(total_fine);
END$$
DELIMITER ;

-- Test: run twice, second run must replace, not double
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary ORDER BY snapshot_date;

-- Schedule daily at 00:10 for CURRENT_DATE
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_refresh_overdue;
DELIMITER $$
CREATE EVENT evt_refresh_overdue
ON SCHEDULE EVERY 1 DAY STARTS '2026-11-26 00:10:00'
DO
BEGIN
    CALL pr_refresh_overdue(CURRENT_DATE);
END$$
DELIMITER ;
