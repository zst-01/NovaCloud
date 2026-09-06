CREATE TABLE IF NOT EXISTS tickets (
  id BIGINT PRIMARY KEY,
  title VARCHAR(200) NOT NULL,
  status VARCHAR(20) NOT NULL
);
INSERT INTO tickets (id, title, status) VALUES (1, 'Demo after-sales ticket', 'OPEN');
