# ICT371 - Advanced Database

## Assignment Submission

Student: Titus Malama Bwalya Jr.
Course: ICT371 Advanced Database

This repository contains SQL solutions for all 10 questions.
Each question is 50 marks and covers tables, functions, procedures,
triggers, views, indexes and scheduled jobs.

## Questions

| Question | Topic | File |
| --- | --- | --- |
| Q1 | Pharmacy Stock and Daily Sales | Question1_Pharmacy.sql |
| Q2 | University Fee Payments | Question2_Fee_Payments.sql |
| Q3 | Library Returns and Overdue Fines | Question3_Library.sql |
| Q4 | Clinic Appointment Scheduling | Question4_Clinic.sql |
| Q5 | Hostel Room Allocation | Question5_Hostel.sql |
| Q6 | Monthly Payroll Processing | Question6_Payroll.sql |
| Q7 | Water Meter Readings and Billing | Question7_Water.sql |
| Q8 | Transport Fleet Maintenance | Question8_Fleet.sql |
| Q9 | Farmer Cooperative Maize Deliveries | Question9_Maize.sql |
| Q10 | Scholarship Application Assessment | Question10_Scholarship.sql |

## How to Run

1. Open MySQL Workbench / phpMyAdmin
2. Open any `QuestionX_*.sql` file
3. Run the whole file
4. Each file creates its own database, tables, seed data,
   function, procedure, trigger, view, index and scheduled event.

## Notes

- All files use MySQL syntax.
- Seed data is loaded through procedures / triggers where required.
- Scheduled jobs use MySQL EVENTS - ensure `event_scheduler = ON`.
