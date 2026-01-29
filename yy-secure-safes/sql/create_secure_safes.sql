-- Run this once in your MySQL/MariaDB server to pre-create the table and avoid runtime DDL delays
CREATE TABLE IF NOT EXISTS `secure_safes` (
  `id` VARCHAR(50) PRIMARY KEY,
  `owner` VARCHAR(50) NOT NULL,
  `tier` INT NOT NULL,
  `passcode` VARCHAR(6) NOT NULL,
  `position` JSON NOT NULL,
  `rotation` JSON NOT NULL,
  `breach_attempts` INT DEFAULT 0,
  `last_breach_time` TIMESTAMP NULL DEFAULT NULL,
  `is_locked` TINYINT(1) DEFAULT 1,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;