SET sql_mode = "NO_ENGINE_SUBSTITUTION";

--
-- PacketFence SQL schema upgrade from 13.1 to 13.2
--


--
-- Setting the major/minor version of the DB
--

SET @MAJOR_VERSION = 13;
SET @MINOR_VERSION = 2;


SET @PREV_MAJOR_VERSION = 13;
SET @PREV_MINOR_VERSION = 1;

--
-- The VERSION_INT to ensure proper ordering of the version in queries
--

SET @VERSION_INT = @MAJOR_VERSION << 16 | @MINOR_VERSION << 8;

SET @PREV_VERSION_INT = @PREV_MAJOR_VERSION << 16 | @PREV_MINOR_VERSION << 8;

DROP PROCEDURE IF EXISTS ValidateVersion;
--
-- Updating to current version
--
DELIMITER //
CREATE PROCEDURE ValidateVersion()
BEGIN
    DECLARE PREVIOUS_VERSION int(11);
    DECLARE PREVIOUS_VERSION_STRING varchar(11);
    DECLARE _message varchar(255);
    SELECT id, version INTO PREVIOUS_VERSION, PREVIOUS_VERSION_STRING FROM pf_version ORDER BY id DESC LIMIT 1;

      IF PREVIOUS_VERSION != @PREV_VERSION_INT THEN
        SELECT CONCAT('PREVIOUS VERSION ', PREVIOUS_VERSION_STRING, ' DOES NOT MATCH ', CONCAT_WS('.', @PREV_MAJOR_VERSION, @PREV_MINOR_VERSION)) INTO _message;
        SIGNAL SQLSTATE VALUE '99999'
              SET MESSAGE_TEXT = _message;
      END IF;
END
//

DELIMITER ;

\! echo "Checking PacketFence schema version...";
call ValidateVersion;

DROP PROCEDURE IF EXISTS ValidateVersion;

\! echo "altering sms_carrier"
ALTER TABLE sms_carrier
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

\! echo "altering admin_api_audit_log"
ALTER TABLE admin_api_audit_log
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

\! echo "creating table node_meta"
CREATE TABLE IF NOT EXISTS node_meta (
    `name` varchar(255) NOT NULL,
    `mac` varchar(17) NOT NULL,
    `value` MEDIUMBLOB NULL,
    PRIMARY KEY(name, mac)
) ENGINE=InnoDB DEFAULT CHARACTER SET = 'utf8mb4' COLLATE = 'utf8mb4_general_ci' ROW_FORMAT=COMPRESSED;

\! echo "Incrementing PacketFence schema version...";
INSERT IGNORE INTO pf_version (id, version, created_at) VALUES (@VERSION_INT, CONCAT_WS('.', @MAJOR_VERSION, @MINOR_VERSION), NOW());


\! echo "Upgrade completed successfully.";
