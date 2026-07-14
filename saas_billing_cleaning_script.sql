-- =====================================================================
-- SaaS Billing & Subscriptions - DATA CLEANING SCRIPT (MySQL 8+)
-- Portfolio project by: Chirag
--
-- What this script does:
--   1. Creates CLEAN versions of the messy tables (raw tables are left
--      untouched, so you can always show "before vs after" in interviews)
--   2. Fixes dates, currency amounts, spelling/casing issues, duplicates,
--      messy names, and inconsistent country names
--   3. Ends with a "Data Quality Summary" - a before/after report you can
--      screenshot for your portfolio or explain in an interview
--
-- Run this AFTER running saas_billing_dirty_dataset.sql
-- =====================================================================

USE saas_billing_practice;

-- =====================================================================
-- STEP 1: Create a helper FUNCTION to fix name casing
-- (turns "JOHN SMITH" or "john smith" into "John Smith")
-- =====================================================================
DROP FUNCTION IF EXISTS proper_case;

DELIMITER $$
CREATE FUNCTION proper_case(input_str VARCHAR(150))
RETURNS VARCHAR(150)
DETERMINISTIC
BEGIN
    DECLARE result VARCHAR(150) DEFAULT '';
    DECLARE remaining VARCHAR(150);
    DECLARE one_word VARCHAR(150);
    DECLARE space_pos INT;

    SET remaining = TRIM(input_str);

    -- Loop through the string one word at a time
    WHILE LENGTH(remaining) > 0 DO
        SET space_pos = LOCATE(' ', remaining);

        IF space_pos = 0 THEN
            SET one_word = remaining;
            SET remaining = '';
        ELSE
            SET one_word = LEFT(remaining, space_pos - 1);
            SET remaining = TRIM(SUBSTRING(remaining, space_pos + 1));
        END IF;

        -- Capitalize first letter, lowercase the rest, then glue back together
        SET result = TRIM(CONCAT(result, ' ',
            CONCAT(UPPER(LEFT(one_word,1)), LOWER(SUBSTRING(one_word,2)))));
    END WHILE;

    RETURN result;
END$$
DELIMITER ;


-- =====================================================================
-- STEP 2: Clean the CUSTOMERS table
-- =====================================================================
DROP TABLE IF EXISTS customers_clean;

CREATE TABLE customers_clean AS
SELECT
    customer_id,

    -- Fix: trim spaces + fix casing (JOHN SMITH / john smith -> John Smith)
    proper_case(TRIM(customer_name)) AS customer_name,

    email,

    -- Flag whether the email is missing or badly formed (no '@' + '.')
    CASE
        WHEN email IS NULL THEN 'Missing'
        WHEN email NOT LIKE '%@%.%' THEN 'Invalid Format'
        ELSE 'Valid'
    END AS email_status,

    -- Fix: collapse USA / US / United States / usa / U.S.A into one value
    CASE
        WHEN LOWER(TRIM(country)) IN ('usa','us','united states','u.s.a') THEN 'United States'
        WHEN LOWER(TRIM(country)) IN ('uk','united kingdom') THEN 'United Kingdom'
        WHEN LOWER(TRIM(country)) = 'india' THEN 'India'
        ELSE TRIM(country)
    END AS country,

    signup_date

FROM customers;

ALTER TABLE customers_clean ADD PRIMARY KEY (customer_id);


-- =====================================================================
-- STEP 3: Clean the BILLING_TRANSACTIONS table
-- =====================================================================
DROP TABLE IF EXISTS billing_transactions_clean;

CREATE TABLE billing_transactions_clean AS
WITH deduped AS (
    -- Step 3a: Number every row within each invoice_id group.
    -- rn = 1 means "keep this one", rn > 1 means "this is a duplicate"
    SELECT
        bt.*,
        ROW_NUMBER() OVER (PARTITION BY invoice_id ORDER BY row_id) AS rn
    FROM billing_transactions bt
)
SELECT
    row_id,
    invoice_id,
    customer_id,
    plan_id,

    -- Fix: convert every text date format into a real DATE
    CASE
        WHEN invoice_date IS NULL OR TRIM(invoice_date) = '' THEN NULL
        WHEN invoice_date REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(invoice_date, '%m/%d/%Y')
        WHEN invoice_date REGEXP '^[0-9]{2}-[0-9]{2}-[0-9]{4}$' THEN STR_TO_DATE(invoice_date, '%d-%m-%Y')
        WHEN invoice_date REGEXP '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN STR_TO_DATE(invoice_date, '%Y/%m/%d')
        WHEN invoice_date REGEXP '^[0-9]{2} [A-Za-z]{3} [0-9]{4}$' THEN STR_TO_DATE(invoice_date, '%d %b %Y')
        WHEN invoice_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(invoice_date, '%Y-%m-%d')
        ELSE NULL
    END AS invoice_date,

    -- Fix: strip $ signs, commas, and "USD" text, then convert to a real number
    CASE
        WHEN amount IS NULL OR TRIM(amount) = '' THEN NULL
        ELSE CAST(
                REPLACE(REPLACE(REPLACE(TRIM(amount), '$', ''), ',', ''), ' USD', '')
             AS DECIMAL(10,2))
    END AS amount,

    -- Fix: standardize status spelling + casing
    CASE
        WHEN LOWER(TRIM(status)) = 'active' THEN 'Active'
        WHEN LOWER(TRIM(status)) IN ('cancelled','canceled') THEN 'Cancelled'
        WHEN LOWER(TRIM(status)) = 'churned' THEN 'Churned'
        WHEN LOWER(TRIM(status)) = 'trial' THEN 'Trial'
        ELSE TRIM(status)
    END AS status,

    -- Fix: standardize payment method casing
    CASE
        WHEN LOWER(TRIM(payment_method)) = 'credit card' THEN 'Credit Card'
        WHEN LOWER(TRIM(payment_method)) = 'paypal' THEN 'PayPal'
        WHEN LOWER(TRIM(payment_method)) = 'bank transfer' THEN 'Bank Transfer'
        ELSE TRIM(payment_method)
    END AS payment_method,

    -- Fix: strip the % sign and convert to a whole number (NULL stays NULL)
    CASE
        WHEN discount_pct IS NULL THEN NULL
        ELSE CAST(REPLACE(discount_pct, '%', '') AS UNSIGNED)
    END AS discount_pct,

    -- Fix: trim whitespace, turn "N/A" into a real NULL
    CASE
        WHEN notes IS NULL THEN NULL
        WHEN TRIM(notes) = 'N/A' THEN NULL
        ELSE TRIM(notes)
    END AS notes

FROM deduped
WHERE rn = 1;      -- Step 3b: this line removes the duplicate invoice_id rows

ALTER TABLE billing_transactions_clean ADD PRIMARY KEY (row_id);
CREATE INDEX idx_btc_invoice_id ON billing_transactions_clean (invoice_id);
CREATE INDEX idx_btc_customer_id ON billing_transactions_clean (customer_id);


-- =====================================================================
-- STEP 4: DATA QUALITY SUMMARY (before vs after)
-- Run these one at a time and note down the numbers - great for your
-- portfolio README or to explain in an interview.
-- =====================================================================

-- How many duplicate invoice_id rows did we remove?
SELECT
    (SELECT COUNT(*) FROM billing_transactions) AS raw_row_count,
    (SELECT COUNT(*) FROM billing_transactions_clean) AS clean_row_count,
    (SELECT COUNT(*) FROM billing_transactions) -
        (SELECT COUNT(*) FROM billing_transactions_clean) AS duplicates_removed;

-- How many invoice_date values were blank/NULL and couldn't be recovered?
SELECT COUNT(*) AS missing_dates
FROM billing_transactions_clean
WHERE invoice_date IS NULL;

-- How many amount values were blank/NULL?
SELECT COUNT(*) AS missing_amounts
FROM billing_transactions_clean
WHERE amount IS NULL;

-- How many customer emails are missing or invalid?
SELECT email_status, COUNT(*) AS customer_count
FROM customers_clean
GROUP BY email_status;

-- Distinct status values before vs after (should shrink from 9 to 4)
SELECT 'BEFORE' AS stage, status, COUNT(*) AS cnt FROM billing_transactions GROUP BY status
UNION ALL
SELECT 'AFTER' AS stage, status, COUNT(*) AS cnt FROM billing_transactions_clean GROUP BY status
ORDER BY stage, status;

-- Distinct country values before vs after (should shrink from 10 to 3)
SELECT 'BEFORE' AS stage, country, COUNT(*) AS cnt FROM customers GROUP BY country
UNION ALL
SELECT 'AFTER' AS stage, country, COUNT(*) AS cnt FROM customers_clean GROUP BY country
ORDER BY stage, country;
