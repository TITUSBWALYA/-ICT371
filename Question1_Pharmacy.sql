-- ============================================================
-- Question 1: Pharmacy Stock and Daily Sales - 50 marks
-- ============================================================
DROP DATABASE IF EXISTS pharmacy_db;
CREATE DATABASE pharmacy_db;
USE pharmacy_db;

-- (a) Database and seed data
CREATE TABLE medicines (
    medicine_id INT PRIMARY KEY AUTO_INCREMENT,
    medicine_name VARCHAR(100) NOT NULL UNIQUE,
    unit_price DECIMAL(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id INT PRIMARY KEY AUTO_INCREMENT,
    medicine_id INT NOT NULL,
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price DECIMAL(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL,
    FOREIGN KEY (medicine_id) REFERENCES medicines(medicine_id)
);

CREATE TABLE stock_audit (
    audit_id INT PRIMARY KEY AUTO_INCREMENT,
    medicine_id INT NOT NULL,
    old_qty INT NOT NULL,
    new_qty INT NOT NULL,
    changed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (medicine_id) REFERENCES medicines(medicine_id)
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INT NOT NULL DEFAULT 0,
    total_amount DECIMAL(12,2) NOT NULL DEFAULT 0
);

-- Seed medicines (at least 3)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
('Paracetamol 500mg', 5.00, 100),
('Amoxicillin 250mg', 12.50, 50),
('Vitamin C 1000mg', 8.00, 8);

-- (b) Function: fn_sale_value(p_medicine_id, p_quantity)
DELIMITER $$
CREATE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS DECIMAL(12,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_price DECIMAL(10,2);
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid quantity: must be positive';
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF v_price IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown medicine';
    END IF;
    RETURN v_price * p_quantity;
END$$
DELIMITER ;

-- (c) Procedure: pr_record_sale(p_medicine_id, p_quantity, p_sold_on)
DELIMITER $$
CREATE PROCEDURE pr_record_sale(
    IN p_medicine_id INT,
    IN p_quantity INT,
    IN p_sold_on DATE
)
BEGIN
    DECLARE v_stock INT;
    DECLARE v_price DECIMAL(10,2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid quantity: must be positive';
    END IF;
    IF p_sold_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid sold_on date';
    END IF;
    START TRANSACTION;
    -- Lock the medicine row so stock is deducted exactly once
    SELECT stock_qty, unit_price INTO v_stock, v_price
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF v_price IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown medicine';
    END IF;
    IF v_stock < p_quantity THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient stock: would oversell';
    END IF;
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
    COMMIT;
END$$
DELIMITER ;

-- (a continued) Seed 6 valid sales THROUGH the procedure
CALL pr_record_sale(1, 10, '2026-11-20');
CALL pr_record_sale(1, 5, '2026-11-20');
CALL pr_record_sale(2, 4, '2026-11-21');
CALL pr_record_sale(2, 2, '2026-11-21');
CALL pr_record_sale(3, 2, '2026-11-22');
CALL pr_record_sale(1, 3, '2026-11-22');

-- Test invalid sale leaves tables unchanged (should fail, no oversell):
-- CALL pr_record_sale(3, 100, '2026-11-22');

-- (d) Trigger: AFTER UPDATE on medicines, audit only when stock changes
DELIMITER $$
CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
BEGIN
    IF OLD.stock_qty <> NEW.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, NOW());
    END IF;
END$$
DELIMITER ;

-- Trigger test: this sale should create an audit row
CALL pr_record_sale(1, 2, '2026-11-23');

-- (e) View: v_low_stock - stock_qty below 10
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name AS name, unit_price AS price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Query the view after a sale
SELECT * FROM v_low_stock;

-- (f) Index: find one medicine's sales within a sold_on date range
-- Justification: queries filter by medicine_id equality first, then sold_on range.
-- Composite (medicine_id, sold_on) lets MySQL seek to that medicine then scan only its dates.
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);

-- Show EXPLAIN for a matching query
EXPLAIN SELECT * FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN '2026-11-20' AND '2026-11-22';

-- (g) Scheduled job: pr_refresh_sales(p_day)
DELIMITER $$
CREATE PROCEDURE pr_refresh_sales(IN p_day DATE)
BEGIN
    -- Replace that day's totals. Rerunning does NOT duplicate / double-count
    -- because daily_sales.sales_date is PK and we use ON DUPLICATE KEY UPDATE.
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
    ON DUPLICATE KEY UPDATE
        total_qty = VALUES(total_qty),
        total_amount = VALUES(total_amount);
END$$
DELIMITER ;

-- Test refresh (run twice - second run must give same totals, not double)
CALL pr_refresh_sales('2026-11-20');
CALL pr_refresh_sales('2026-11-20');
SELECT * FROM daily_sales ORDER BY sales_date;

-- Schedule daily at 00:15 for the previous day
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_refresh_daily_sales;
DELIMITER $$
CREATE EVENT evt_refresh_daily_sales
ON SCHEDULE EVERY 1 DAY STARTS '2026-11-24 00:15:00'
DO
BEGIN
    CALL pr_refresh_sales(DATE_SUB(CURDATE(), INTERVAL 1 DAY));
END$$
DELIMITER ;
