-- ============================================================
-- Question 8: Transport Fleet Maintenance - 50 marks
-- Service alert when >= 5,000 km since last service.
-- Each new trip must start at the vehicle's CURRENT odometer.
-- ============================================================
DROP DATABASE IF EXISTS fleet_db;
CREATE DATABASE fleet_db;
USE fleet_db;

-- (a) Tables
CREATE TABLE vehicles (
    vehicle_id INT PRIMARY KEY AUTO_INCREMENT,
    registration VARCHAR(20) NOT NULL UNIQUE,
    current_odometer DECIMAL(12,2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer DECIMAL(12,2) NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id INT PRIMARY KEY AUTO_INCREMENT,
    vehicle_id INT NOT NULL,
    trip_on DATE NOT NULL,
    start_odometer DECIMAL(12,2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer DECIMAL(12,2) NOT NULL CHECK (end_odometer >= 0),
    FOREIGN KEY (vehicle_id) REFERENCES vehicles(vehicle_id)
);

CREATE TABLE service_alerts (
    vehicle_id INT PRIMARY KEY,
    km_since_service DECIMAL(12,2) NOT NULL,
    flagged_on DATE NOT NULL,
    FOREIGN KEY (vehicle_id) REFERENCES vehicles(vehicle_id)
);

-- Seed 3 vehicles, different service positions
-- V1: 6000 km since service = DUE, V2: 3000 = not due, V3: 4900 = not due (close)
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('REG001', 12000, 6000),
('REG002', 8000, 5000),
('REG003', 4900, 0);

-- (b) Function: fn_service_due(p_vehicle_id) - TRUE if >= 5000 km since service
DELIMITER $$
CREATE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_curr DECIMAL(12,2);
    DECLARE v_last DECIMAL(12,2);
    SELECT current_odometer, last_service_odometer INTO v_curr, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF v_curr IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown vehicle';
    END IF;
    RETURN (v_curr - v_last) >= 5000;
END$$
DELIMITER ;

-- (c) Procedure: pr_record_trip(p_vehicle_id, p_trip_on, p_start, p_end)
-- Validates vehicle, requires end > start. Does NOT update vehicle odometer -
-- the TRIGGER does that exactly once.
DELIMITER $$
CREATE PROCEDURE pr_record_trip(
    IN p_vehicle_id INT,
    IN p_trip_on DATE,
    IN p_start DECIMAL(12,2),
    IN p_end DECIMAL(12,2)
)
BEGIN
    DECLARE v_exists INT;
    SELECT COUNT(*) INTO v_exists FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF v_exists = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown vehicle';
    END IF;
    IF p_trip_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid trip date';
    END IF;
    IF p_end <= p_start THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'end_odometer must be greater than start_odometer';
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END$$
DELIMITER ;

-- (d) Trigger: BEFORE INSERT on trips
-- Verifies start = vehicle's current odometer, rejects invalid mileage,
-- and updates current_odometer to trip end EXACTLY ONCE.
DELIMITER $$
CREATE TRIGGER trg_trips_check_and_update_odometer
BEFORE INSERT ON trips
FOR EACH ROW
BEGIN
    DECLARE v_curr DECIMAL(12,2);
    SELECT current_odometer INTO v_curr FROM vehicles WHERE vehicle_id = NEW.vehicle_id;
    IF v_curr IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown vehicle';
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid mileage: end must be greater than start';
    END IF;
    IF NEW.start_odometer <> v_curr THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trip must start at vehicle current odometer';
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;
END$$
DELIMITER ;

-- (a continued) Seed 6 trips THROUGH the procedure, AFTER trigger is installed
-- Each start = current odometer at that moment (trigger then moves it forward)
CALL pr_record_trip(1, '2026-11-20', 12000, 12500); -- V1: 12000 -> 12500
CALL pr_record_trip(2, '2026-11-20', 8000, 8300);   -- V2: 8000 -> 8300
CALL pr_record_trip(3, '2026-11-21', 4900, 5100);   -- V3: 4900 -> 5100, now crosses 5000
CALL pr_record_trip(1, '2026-11-22', 12500, 13000); -- V1: 12500 -> 13000
CALL pr_record_trip(2, '2026-11-23', 8300, 8500);   -- V2: 8300 -> 8500
CALL pr_record_trip(3, '2026-11-24', 5100, 5200);   -- V3: 5100 -> 5200

-- Invalid examples (should fail, vehicle odometer unchanged):
-- CALL pr_record_trip(1, '2026-11-25', 12000, 13500); -- start != current (13000)
-- CALL pr_record_trip(1, '2026-11-25', 13000, 13000); -- end not > start

SELECT vehicle_id, registration, current_odometer, last_service_odometer,
       (current_odometer - last_service_odometer) AS km_since_service,
       fn_service_due(vehicle_id) AS service_due
FROM vehicles;

-- (e) View: v_service_due - only vehicles meeting threshold
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

SELECT * FROM v_service_due;

-- (f) Index: one vehicle's trips within a trip_on date range
-- Justification: equality on vehicle_id first, then range on trip_on.
-- Composite (vehicle_id, trip_on) seeks straight to that vehicle's trips
-- in that date range instead of scanning all trips.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN '2026-11-20' AND '2026-11-24';

-- (g) Scheduled job: pr_refresh_service_alerts()
-- Insert/update one alert per due vehicle, remove alert when no longer due
DELIMITER $$
CREATE PROCEDURE pr_refresh_service_alerts()
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           (current_odometer - last_service_odometer),
           CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON DUPLICATE KEY UPDATE
        km_since_service = VALUES(km_since_service),
        flagged_on = VALUES(flagged_on);
    DELETE FROM service_alerts
    WHERE vehicle_id IN (
        SELECT vehicle_id FROM vehicles
        WHERE (current_odometer - last_service_odometer) < 5000
    );
END$$
DELIMITER ;

-- Test
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- Simulate service: V1 serviced at 13000, alert must disappear on next refresh
UPDATE vehicles SET last_service_odometer = 13000 WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;
-- Restore for marking: V1 due again
UPDATE vehicles SET last_service_odometer = 6000 WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();

-- Schedule every Monday at 06:00 (next Monday = 2026-11-30)
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_refresh_service_alerts;
DELIMITER $$
CREATE EVENT evt_refresh_service_alerts
ON SCHEDULE EVERY 1 WEEK STARTS '2026-11-30 06:00:00'
DO
BEGIN
    CALL pr_refresh_service_alerts();
END$$
DELIMITER ;
