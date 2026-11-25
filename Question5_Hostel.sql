-- ============================================================
-- Question 5: Hostel Room Allocation - 50 marks
-- No room over capacity. One ACTIVE allocation per student.
-- ENDED = history, does NOT occupy a bed.
-- ============================================================
DROP DATABASE IF EXISTS hostel_db;
CREATE DATABASE hostel_db;
USE hostel_db;

-- (a) Tables
CREATE TABLE students (
    student_id INT PRIMARY KEY AUTO_INCREMENT,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id INT PRIMARY KEY AUTO_INCREMENT,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id INT PRIMARY KEY AUTO_INCREMENT,
    student_id INT NOT NULL,
    room_id INT NOT NULL,
    allocated_on DATE NOT NULL,
    released_on DATE NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL)
    ),
    FOREIGN KEY (student_id) REFERENCES students(student_id),
    FOREIGN KEY (room_id) REFERENCES rooms(room_id)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL,
    occupied_beds INT NOT NULL DEFAULT 0,
    free_beds INT NOT NULL DEFAULT 0,
    PRIMARY KEY (snapshot_date, room_id),
    FOREIGN KEY (room_id) REFERENCES rooms(room_id)
);

-- Seed students and rooms
INSERT INTO students (student_number, full_name) VALUES
('STU101', 'Titus Bwalya'),
('STU102', 'Grace Mwale'),
('STU103', 'Peter Phiri'),
('STU104', 'Emma Chanda'),
('STU105', 'Frank Tembo');

INSERT INTO rooms (room_number, capacity) VALUES
('101', 2),
('102', 3),
('103', 2);

-- (b) Function: fn_free_beds(p_room_id)
DELIMITER $$
CREATE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_cap INT;
    DECLARE v_active INT;
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF v_cap IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
    END IF;
    SELECT COUNT(*) INTO v_active FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';
    RETURN v_cap - v_active;
END$$
DELIMITER ;

-- (c) Procedure: pr_allocate_room(p_student_id, p_room_id, p_allocated_on)
DELIMITER $$
CREATE PROCEDURE pr_allocate_room(
    IN p_student_id INT,
    IN p_room_id INT,
    IN p_allocated_on DATE
)
BEGIN
    DECLARE v_s INT;
    DECLARE v_r INT;
    DECLARE v_has_active INT;
    SELECT COUNT(*) INTO v_s FROM students WHERE student_id = p_student_id;
    IF v_s = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    END IF;
    SELECT COUNT(*) INTO v_r FROM rooms WHERE room_id = p_room_id;
    IF v_r = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
    END IF;
    IF p_allocated_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid allocated_on date';
    END IF;
    SELECT COUNT(*) INTO v_has_active FROM allocations
    WHERE student_id = p_student_id AND status = 'ACTIVE';
    IF v_has_active > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room is full: no free beds';
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END$$
DELIMITER ;

-- (d) Trigger: BEFORE INSERT OR UPDATE - enforce capacity + one ACTIVE per student
-- MySQL needs two triggers with the same logic. On UPDATE we exclude the row being updated.
DELIMITER $$
CREATE TRIGGER trg_allocations_check_ins
BEFORE INSERT ON allocations
FOR EACH ROW
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (SELECT 1 FROM allocations WHERE student_id = NEW.student_id AND status = 'ACTIVE') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
        END IF;
        IF fn_free_beds(NEW.room_id) <= 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room is full: no free beds';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_allocations_check_upd
BEFORE UPDATE ON allocations
FOR EACH ROW
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (SELECT 1 FROM allocations WHERE student_id = NEW.student_id AND status = 'ACTIVE' AND allocation_id <> NEW.allocation_id) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
        END IF;
        -- Count OTHER active allocations in this room, excluding this row
        IF (SELECT capacity FROM rooms WHERE room_id = NEW.room_id)
           - (SELECT COUNT(*) FROM allocations WHERE room_id = NEW.room_id AND status = 'ACTIVE' AND allocation_id <> NEW.allocation_id) <= 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room is full: no free beds';
        END IF;
    END IF;
END$$
DELIMITER ;

-- (a continued) Seed allocations
-- Room 101 (cap 2) = FULL, Room 102 (cap 3) = PARTLY OCCUPIED, Room 103 (cap 2) = EMPTY
CALL pr_allocate_room(1, 1, '2026-11-01'); -- Titus -> 101
CALL pr_allocate_room(2, 1, '2026-11-01'); -- Grace -> 101 (now full)
CALL pr_allocate_room(3, 2, '2026-11-01'); -- Peter -> 102

-- ENDED history: does NOT occupy a bed. Inserted directly, trigger allows it.
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 2, '2026-10-01', '2026-11-10', 'ENDED');

-- Invalid examples (should fail):
-- CALL pr_allocate_room(5, 1, '2026-11-20'); -- Room 101 full
-- CALL pr_allocate_room(1, 2, '2026-11-20'); -- Titus already ACTIVE

SELECT fn_free_beds(1) AS free_101_full, fn_free_beds(2) AS free_102, fn_free_beds(3) AS free_103_empty;

-- (e) View: v_room_occupancy - every room, including rooms with no allocations
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       (r.capacity - COUNT(a.allocation_id)) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;

-- (f) Index: ACTIVE allocations filtered by room_id
-- Justification: equality on room_id first, then filter status='ACTIVE'.
-- Composite (room_id, status) seeks straight to that room's ACTIVE rows.
CREATE INDEX idx_allocations_room_status ON allocations (room_id, status);

EXPLAIN SELECT * FROM allocations
WHERE room_id = 1 AND status = 'ACTIVE';

-- (g) Scheduled job: pr_refresh_occupancy() - CURRENT_DATE for every room
DELIMITER $$
CREATE PROCEDURE pr_refresh_occupancy()
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
    ON DUPLICATE KEY UPDATE
        occupied_beds = VALUES(occupied_beds),
        free_beds = VALUES(free_beds);
END$$
DELIMITER ;

-- Test: run twice, second run must replace, not duplicate
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

-- Schedule daily at 23:55
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS evt_refresh_occupancy;
DELIMITER $$
CREATE EVENT evt_refresh_occupancy
ON SCHEDULE EVERY 1 DAY STARTS '2026-11-25 23:55:00'
DO
BEGIN
    CALL pr_refresh_occupancy();
END$$
DELIMITER ;
