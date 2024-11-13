DROP DATABASE IF EXISTS ForexFactory;
CREATE DATABASE ForexFactory;

USE ForexFactory;

CREATE TABLE IF NOT EXISTS Currencies (
    currency_id INT AUTO_INCREMENT PRIMARY KEY,
    Currency VARCHAR(255)
);

INSERT INTO Currencies (Currency) VALUES ('USD'), ('EUR'), ('JPY'), ('GBP');

CREATE TABLE IF NOT EXISTS FX_News (
    id INT AUTO_INCREMENT PRIMARY KEY,
    date_time DATETIME,
    AllDay BIT,
    currency_id INT,
    Impact VARCHAR(255),
    Detail VARCHAR(255),
    Actual FLOAT,
    Forecast FLOAT,
    Previous FLOAT,
    UNIQUE (date_time, AllDay, currency_id, Detail),
    FOREIGN KEY (currency_id) REFERENCES Currencies(currency_id)
);

