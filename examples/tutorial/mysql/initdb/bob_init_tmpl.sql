CREATE DATABASE IF NOT EXISTS `bob`;
USE `bob`;

DROP TABLE IF EXISTS `lineitem`;
CREATE TABLE `lineitem` (
	`orderkey` int not NULL,
	`commitdate` int not null,
	`receiptdate` int not null
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

LOCK TABLES `lineitem` WRITE;
INSERT INTO `user_stats` VALUES ("id0001", 3598.0, 1);
INSERT INTO `user_stats` VALUES ("id0002", 100.0, 0);
INSERT INTO `user_stats` VALUES ("id0003", 2549.0, 1);
INSERT INTO `user_stats` VALUES ("id0004", 21698.5, 1);
INSERT INTO `user_stats` VALUES ("id0005", 4985.5, 1);
INSERT INTO `user_stats` VALUES ("id0006", 3598.0, 1);
INSERT INTO `user_stats` VALUES ("id0007", 322, 0);
INSERT INTO `user_stats` VALUES ("id0008", 9816.2, 1);
INSERT INTO `user_stats` VALUES ("id0009", 3598.0, 1);
INSERT INTO `user_stats` VALUES ("id0010", 322, 0);
INSERT INTO `user_stats` VALUES ("id0011", 9816.2, 1);
INSERT INTO `user_stats` VALUES ("id0012", 3598.0, 1);
INSERT INTO `user_stats` VALUES ("id0013", 322, 0);
INSERT INTO `user_stats` VALUES ("id0014", 9816.2, 1);
INSERT INTO `user_stats` VALUES ("id0015", 9816.2, 1);
INSERT INTO `user_stats` VALUES ("id0016", 9816.2, 1);
INSERT INTO `user_stats` VALUES ("id0017", 3598.0, 1);
INSERT INTO `user_stats` VALUES ("id0018", 322, 0);
INSERT INTO `user_stats` VALUES ("id0019", 9816.2, 1);
INSERT INTO `user_stats` VALUES ("id0020", 9816.2, 1);
INSERT INTO `user_stats` VALUES ("id0087", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0088", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0089", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0090", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0091", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0093", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0094", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0095", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0096", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0097", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0098", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0099", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0100", 1322, 1);
INSERT INTO `user_stats` VALUES ("id0101", 1322, 1);
UNLOCK TABLES;
