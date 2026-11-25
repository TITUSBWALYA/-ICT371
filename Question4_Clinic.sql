-- ============================================================
-- Question 4: Clinic Appointment Scheduling - 50 marks
-- Slots: 09:00, 10:00, 11:00, 12:00 only.
-- Two non-cancelled appointments must never share doctor + date + slot.
-- ============================================================
DROP DATABASE IF EXISTS clinic_db;
CREATE DATABASE clinic_db;
USE clinic_db;

-- (a) Tables
CREATE TABLE patients (
    patient_id INT PRIMARY KEY AUTO_INCREMENT,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id INT PRIMARY KEY AUTO_INCREMENT,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id INT PRIMARY KEY AUTO_INCREMENT,
    patient_id INT NOT NULL,
    doctor_id INT NOT NULL,
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED','ATTENDED','CANCELLED')),
    FOREIGN KEY (patient_id) REFERENCES patients(patient_id),
    FOREIGN KEY (doctor_id) REFERENCES doctors(doctor_id)
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL DEFAULT 0,
    attended_count INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
);

-- Seed 3 patients, 3 doctors
INSERT INTO patients (full_name) VALUES
('Titus Bwalya'), ('Grace Mwale'), ('Peter Phiri');

INSERT INTO doctors (full_name) VALUES
('Dr. Chanda'), ('Dr. Zulu'), ('Dr. Banda');

-- (b) Function: fn_daily_load(p_doctor_id, p_day)
DELIMITER $$
CREATE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_exists INT;
    SELECT COUNT(*) INTO v_exists FROM doctors WHERE doctor_id = p_doctor_id;
    IF v_exists = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown doctor';
    END IF;
    RETURN (
        SELECT COUNT(*) FROM appointments
        WHERE doctor_id = p_doctor_id
          AND appointment_day = p_day
          AND status <> 'CANCELLED'
    );
END$$
DELIMITER ;

-- (c) Procedure: pr_book_appointment(p_patient_id, p_doctor_id, p_day, p_slot)
DELIMITER $$
CREATE PROCEDURE pr_book_appointment(
    IN p_patient_id INT,
    IN p_doctor_id INT,
    IN p_day DATE,
    IN p_slot TIME
)
BEGIN
    DECLARE v_p INT;
    DECLARE v_d INT;
    SELECT COUNT(*) INTO v_p FROM patients WHERE patient_id = p_patient_id;
    IF v_p = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown patient';
    END IF;
    SELECT COUNT(*) INTO v_d FROM doctors WHERE doctor_id = p_doctor_id;
    IF v_d = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown doctor';
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot book a past date';
    END IF;
    IF p_slot NOT IN ('09:00:00','10:00:00','11:00:00','12:00:00') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unsupported slot: use 09:00, 10:00, 11:00 or 12:00';
    END IF;
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END$$
DELIMITER ;

-- (d) Trigger: BEFORE INSERT OR UPDATE - reject clash with another non-cancelled appointment
-- MySQL does not allow one trigger for INSERT OR UPDATE, so we create two
-- triggers with the same logic. On UPDATE we exclude the row being changed.
DELIMITER $$
CREATE TRIGGER trg_appointments_no_clash_ins
BEFORE INSERT ON appointments
FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT 1 FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot clash: doctor already has a non-cancelled appointment at that date and slot';
    END IF;
END$$

CREATE TRIGGER trg_appointments_no_clash_upd
BEFORE UPDATE ON appointments
FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT 1 FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED'
          AND appointment_id <> NEW.appointment_id
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Slot clash: doctor already has a non-cancelled appointment at that date and slot';
    END IF;
END$$
DELIMITER ;

-- (a continued) Seed 6 appointments THROUGH the procedure
-- We use CURDATE()+1 / +2 so the dates are always in the future when the marker runs it.
CALL pr_book_appointment(1, 1, DATE_ADD(CURDATE(), INTERVAL 1 DAY), '09:00:00');
CALL pr_book_appointment(2, 1, DATE_ADD(CURDATE(), INTERVAL 1 DAY), '10:00:00');
CALL pr_book_appointment(3, 2, DATE_ADD(CURDATE(), INTERVAL 1 DAY), '09:00:00');
CALL pr_book_appointment(1, 2, DATE_ADD(CURDATE(), INTERVAL 2 DAY), '11:00:00');
CALL pr_book_appointment(2, 3, DATE_ADD(CURDATE(), INTERVAL 1 DAY), '12:00:00');
CALL pr_book_appointment(3, 1, DATE_ADD(CURDATE(), INTERVAL 2 DAY), '09:00:00');

-- Show different statuses for the summary test
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 2;

-- Invalid examples (should fail):
-- CALL pr_book_appointment(1, 1, DATE_ADD(CURDATE(), INTERVAL 1 DAY), '09:00:00'); -- clash, Dr1 already BOOKED? No, appt 1 is ATTENDED (non-cancelled) so clash
-- CALL pr_book_appointment(1, 1, DATE_SUB(CURDATE(), INTERVAL 1 DAY), '09:00:00'); -- past date
-- CALL pr_book_appointment(1, 1, DATE_ADD(CURDATE(), INTERVAL 1 DAY), '13:00:00'); -- unsupported slot

-- Test function: 0 when no bookings, count otherwise
SELECT fn_daily_load(1, DATE_ADD(CURDATE(), INTERVAL 1 DAY)) AS load_day1;
SELECT fn_daily_load(1, DATE_ADD(CURDATE(), INTERVAL 5 DAY)) AS load_empty_day;

-- (e) View: v_today_appointments - today's BOOKED only, no unrelated patient data
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name,
       d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments;

-- (f) Index: appointments searched by appointment_day and doctor_id
-- Justification: queries filter by day first (equality/range) then doctor.
-- Composite (appointment_day, doctor_id) is non-unique because one doctor
-- can have many appointments per day and many doctors share a day.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN SELECT * FROM appointments
WHERE appointment_day = DATE_ADD(CURDATE(), INTERVAL 1 DAY)
  AND doctor_id = 1;

-- (g) Scheduled job: pr_refresh_clinic_summary(p_day)
DELIMITER $$
CREATE PROCEDURE pr_refresh_clinic_summary(IN p_day DATE)
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           SUM(status = 'BOOKED'),
           SUM(status = 'ATTENDED'),
           SUM(status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON DUPLICATE KEY UPDATE
        booked_count = VALUES(booked_count),
        attended_count = VALUES(attended_count),
        cancelled_count = VALUES(cancelled_count);
END$$
DELIMITER ;

-- Test: run twice, second run must replace, not double
CALL pr_refresh_clinic_summary(DATE_ADD(CURDATE(), INTERVAL 1 DAY));
CALL pr_refresh_clinic_summary(DATE_ADD(CURDATE(), INTERVAL 1 DAY));
SELECT * FROM clinic_summary ORDER BY summary_date;

-- Schedule daily at 01:00 for previous day
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_refresh_clinic_summary;
DELIMITER $$
CREATE EVENT evt_refresh_clinic_summary
ON SCHEDULE EVERY 1 DAY STARTS '2026-11-26 01:00:00'
DO
BEGIN
    CALL pr_refresh_clinic_summary(DATE_SUB(CURDATE(), INTERVAL 1 DAY));
END$$
DELIMITER ;
