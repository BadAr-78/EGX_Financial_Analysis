USE EGX_Data;
GO

-- 1) DimAccount (built from staging, so Fact can join to it) ----------
-- FinanceIndex follows the typical statement order on the site (average Line_Order).
-- Account_Label is UNIQUE per FinanceIndex (the same Line_Item name can exist in
-- more than one statement), so Power BI can "Sort by column" Account_Label -> FinanceIndex.
CREATE OR ALTER VIEW DimAccount AS
SELECT
    ROW_NUMBER() OVER (ORDER BY Statement, AVG(CAST(Line_Order AS FLOAT)), Line_Item) AS FinanceIndex,
    Statement,
    CASE Statement
        WHEN 'income-statement'    THEN 'Income_Statement'
        WHEN 'balance-sheet'       THEN 'Balance_Sheet'
        WHEN 'cash-flow-statement' THEN 'Cash_Flow'
    END AS Statement_Type,
    Line_Item,
    CONCAT(Line_Item, CASE Statement
        WHEN 'income-statement'    THEN ' [IS]'
        WHEN 'balance-sheet'       THEN ' [BS]'
        WHEN 'cash-flow-statement' THEN ' [CF]'
    END) AS Account_Label
FROM Staging_Financials
GROUP BY Statement, Line_Item;
GO

-- 2) FACT --------------------------------------------------------------
CREATE OR ALTER VIEW Fact_Financials AS
SELECT
    s.Line_Order,
    s.Company,
    CASE s.Statement
        WHEN 'income-statement'    THEN 'Income_Statement'
        WHEN 'balance-sheet'       THEN 'Balance_Sheet'
        WHEN 'cash-flow-statement' THEN 'Cash_Flow'
    END AS Statement_Type,
    a.FinanceIndex,
    s.Line_Item,
    CASE
        -- Quarterly: Q1..Q4 -> months 3, 6, 9, 12
        WHEN s.Period LIKE 'Q[1-4] [0-9][0-9][0-9][0-9]' THEN
            EOMONTH(DATEFROMPARTS(CAST(RIGHT(s.Period, 4) AS INT),
                                  CAST(SUBSTRING(s.Period, 2, 1) AS INT) * 3, 1))
        -- Half-yearly (e.g. IRON): H1 -> June 30, H2 -> December 31
        WHEN s.Period LIKE 'H[1-2] [0-9][0-9][0-9][0-9]' THEN
            EOMONTH(DATEFROMPARTS(CAST(RIGHT(s.Period, 4) AS INT),
                                  CAST(SUBSTRING(s.Period, 2, 1) AS INT) * 6, 1))
    END AS EndOfQuarter,
    s.Amount
FROM Staging_Financials s
JOIN DimAccount a
  ON a.Statement = s.Statement AND a.Line_Item = s.Line_Item
WHERE s.Period LIKE 'Q[1-4] [0-9][0-9][0-9][0-9]'
   OR s.Period LIKE 'H[1-2] [0-9][0-9][0-9][0-9]';   -- drops junk periods such as 'n/a'
GO

-- 3) DimCompany --------------------------------------------------------
CREATE OR ALTER VIEW DimCompany AS
SELECT DISTINCT Company FROM Fact_Financials;
GO

-- 4) DimStatement ------------------------------------------------------
CREATE OR ALTER VIEW DimStatement AS
SELECT DISTINCT Statement_Type FROM Fact_Financials;
GO

-- 5) DimCalendar -------------------------------------------------------
CREATE OR ALTER VIEW DimCalendar AS
SELECT DISTINCT
    EndOfQuarter,
    YEAR(EndOfQuarter) AS Year,
    DATEPART(QUARTER, EndOfQuarter) AS Quarter,
    CONCAT(YEAR(EndOfQuarter), '_', DATEPART(QUARTER, EndOfQuarter)) AS Quarter_Year
FROM Fact_Financials
WHERE EndOfQuarter IS NOT NULL;
GO

-- 6) Fact_Metrics: ONE ROW per company per period, standard KPI columns ----
-- Line item names differ between companies, so COALESCE picks the first one that exists.
-- Flow items (revenue, income, cash flow) are for the period; balance sheet items are closing values.
-- Banks/insurers have different statements, so industrial columns (COGS, inventory...) stay NULL for them.
CREATE OR ALTER VIEW Fact_Metrics AS
WITH p AS (
    SELECT
        Company,
        EndOfQuarter,
        -- Income statement
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Total Revenue'   THEN Amount END) AS is_total_revenue,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Revenue'          THEN Amount END) AS is_revenue,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Revenues Before Loan Losses' THEN Amount END) AS is_rev_bll,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Revenue Before Loan Losses'  THEN Amount END) AS is_rev_bll2,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Operating Revenue' THEN Amount END) AS is_op_revenue,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Cost of Revenue' THEN Amount END) AS is_cogs,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Gross Profit'    THEN Amount END) AS is_gross_profit,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Operating Income' THEN Amount END) AS is_op_income,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Depreciation & Amortization' THEN Amount END) AS is_da,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Interest Expense' THEN Amount END) AS is_interest_exp,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Pretax Income'    THEN Amount END) AS is_pretax,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Income Tax Expense' THEN Amount END) AS is_tax,
        MAX(CASE WHEN Statement_Type='Income_Statement' AND Line_Item='Net Income'       THEN Amount END) AS is_net_income,
        -- Cash flow
        MAX(CASE WHEN Statement_Type='Cash_Flow' AND Line_Item='Depreciation & Amortization, Total' THEN Amount END) AS cf_da_total,
        MAX(CASE WHEN Statement_Type='Cash_Flow' AND Line_Item='Depreciation & Amortization'        THEN Amount END) AS cf_da,
        MAX(CASE WHEN Statement_Type='Cash_Flow' AND Line_Item='Operating Cash Flow' THEN Amount END) AS cf_ocf,
        MAX(CASE WHEN Statement_Type='Cash_Flow' AND Line_Item='Capital Expenditures' THEN Amount END) AS cf_capex,
        -- Balance sheet
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Total Assets'        THEN Amount END) AS bs_assets,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Total Liabilities'   THEN Amount END) AS bs_liab,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Shareholders'' Equity' THEN Amount END) AS bs_equity,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Total Common Equity' THEN Amount END) AS bs_common_equity,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Total Current Assets'      THEN Amount END) AS bs_cur_assets,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Total Current Liabilities' THEN Amount END) AS bs_cur_liab,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Cash & Equivalents'            THEN Amount END) AS bs_cash,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Short-Term Investments'        THEN Amount END) AS bs_sti,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Cash & Short-Term Investments' THEN Amount END) AS bs_cash_sti,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Short-Term Debt'               THEN Amount END) AS bs_st_debt,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Short-Term Borrowings'         THEN Amount END) AS bs_st_borrow,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Current Portion of Long-Term Debt' THEN Amount END) AS bs_cur_ltd,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Current Portion of Leases'     THEN Amount END) AS bs_cur_leases,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Long-Term Debt'                THEN Amount END) AS bs_lt_debt,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Long-Term Leases'              THEN Amount END) AS bs_lt_leases,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Inventory'                     THEN Amount END) AS bs_inventory,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Accounts Receivable'           THEN Amount END) AS bs_ar,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Receivables'                   THEN Amount END) AS bs_receivables,
        MAX(CASE WHEN Statement_Type='Balance_Sheet' AND Line_Item='Accounts Payable'              THEN Amount END) AS bs_ap
    FROM Fact_Financials
    WHERE EndOfQuarter IS NOT NULL
    GROUP BY Company, EndOfQuarter
),
m AS (
    SELECT
        Company,
        EndOfQuarter,
        COALESCE(is_total_revenue, is_revenue, is_rev_bll, is_rev_bll2, is_op_revenue) AS Revenue,
        ABS(is_cogs) AS COGS,
        COALESCE(is_gross_profit,
                 CASE WHEN COALESCE(is_total_revenue, is_revenue) IS NOT NULL AND is_cogs IS NOT NULL
                      THEN COALESCE(is_total_revenue, is_revenue) - ABS(is_cogs) END) AS Gross_Profit,
        is_op_income AS Operating_Income,
        COALESCE(cf_da_total, cf_da, is_da) AS DA,
        is_interest_exp AS Interest_Expense,
        is_pretax AS Pretax_Income,
        is_tax AS Income_Tax,
        is_net_income AS Net_Income,
        cf_ocf AS Operating_Cash_Flow,
        cf_capex AS Capex,
        bs_assets AS Total_Assets,
        bs_liab AS Total_Liabilities,
        COALESCE(bs_equity, bs_common_equity) AS Total_Equity,
        bs_cur_assets AS Current_Assets,
        bs_cur_liab AS Current_Liabilities,
        CASE WHEN bs_assets IS NOT NULL
             THEN COALESCE(bs_cash_sti, COALESCE(bs_cash, 0) + COALESCE(bs_sti, 0)) END AS Cash_And_STI,
        CASE WHEN bs_assets IS NOT NULL
             THEN COALESCE(bs_st_debt, 0) + COALESCE(bs_st_borrow, 0) + COALESCE(bs_cur_ltd, 0)
                + COALESCE(bs_cur_leases, 0) + COALESCE(bs_lt_debt, 0) + COALESCE(bs_lt_leases, 0) END AS Total_Debt,
        bs_inventory AS Inventory,
        COALESCE(bs_ar, bs_receivables) AS Receivables,
        bs_ap AS Payables
    FROM p
)
SELECT
    Company,
    EndOfQuarter,
    Revenue, COGS, Gross_Profit, Operating_Income, DA,
    CASE WHEN Operating_Income IS NOT NULL AND DA IS NOT NULL THEN Operating_Income + ABS(DA) END AS EBITDA,
    Interest_Expense, Pretax_Income, Income_Tax, Net_Income,
    ABS(Interest_Expense) AS Interest_Cost,
    -- Opex = what sits between Gross Profit and Operating Income
    CASE WHEN Gross_Profit IS NOT NULL AND Operating_Income IS NOT NULL
         THEN Gross_Profit - Operating_Income END AS Opex,
    -- Total cost = everything between Revenue and Operating Income
    CASE WHEN Revenue IS NOT NULL AND Operating_Income IS NOT NULL
         THEN Revenue - Operating_Income END AS Total_Cost,
    -- Balancing item so the waterfall ends exactly at Net Income
    -- (non-operating income, unusual items, minority interest, etc.)
    CASE WHEN Operating_Income IS NOT NULL AND Net_Income IS NOT NULL
         THEN Net_Income - (Operating_Income - ABS(COALESCE(Interest_Expense, 0)) - COALESCE(Income_Tax, 0)) END AS Other_Items,
    Operating_Cash_Flow, Capex,
    CASE WHEN Operating_Cash_Flow IS NOT NULL THEN Operating_Cash_Flow - ABS(COALESCE(Capex, 0)) END AS Free_Cash_Flow,
    Total_Assets, Total_Liabilities, Total_Equity, Current_Assets, Current_Liabilities,
    Cash_And_STI, Total_Debt,
    CASE WHEN Total_Debt IS NOT NULL THEN Total_Debt - COALESCE(Cash_And_STI, 0) END AS Net_Debt,
    Inventory, Receivables, Payables
FROM m;
GO

-- =====================================================================
-- CHECKS  (run after the views above; each query returns its own result)
-- =====================================================================

-- C1) Overall staging health. Expected: Companies = 212, Zero_Rows small (~1-2%), Null_Dates = 0
SELECT
    (SELECT COUNT(DISTINCT Company) FROM Staging_Financials)           AS Companies,
    (SELECT COUNT(*) FROM Staging_Financials)                          AS Total_Rows,
    (SELECT COUNT(*) FROM Staging_Financials WHERE Amount = 0)         AS Zero_Rows,
    (SELECT COUNT(*) FROM Fact_Financials WHERE EndOfQuarter IS NULL)  AS Null_Dates;

-- C2) Fact health. Expected: Missing_Account = 0, Null_Dates = 0
SELECT COUNT(*) AS Fact_Rows,
       SUM(CASE WHEN FinanceIndex IS NULL THEN 1 ELSE 0 END) AS Missing_Account,
       SUM(CASE WHEN EndOfQuarter IS NULL THEN 1 ELSE 0 END) AS Null_Dates
FROM Fact_Financials;

-- C3) Rows per company and statement
SELECT Company, Statement, COUNT(*) AS Rows_Count
FROM Staging_Financials
GROUP BY Company, Statement
ORDER BY Company, Statement;

-- C4) Companies missing a statement. Expected: no rows
SELECT Company, COUNT(DISTINCT Statement) AS Statements_Count
FROM Staging_Financials
GROUP BY Company
HAVING COUNT(DISTINCT Statement) < 3;

-- C5) Period formats outside Q# YYYY. Expected: only 'H1/H2 YYYY' (IRON) and 'n/a' (AMOC)
SELECT Period, Company, Statement, COUNT(*) AS Rows_Count
FROM Staging_Financials
WHERE Period NOT LIKE 'Q[1-4] [0-9][0-9][0-9][0-9]'
GROUP BY Period, Company, Statement
ORDER BY Rows_Count DESC;

-- C6) Periods that are dropped from the Fact (neither Q# nor H# format). Expected: only 'n/a'
SELECT DISTINCT Period, Company
FROM Staging_Financials
WHERE Period NOT LIKE 'Q[1-4] [0-9][0-9][0-9][0-9]'
  AND Period NOT LIKE 'H[1-2] [0-9][0-9][0-9][0-9]';

-- C7) Negative numbers are kept. Expected: rows returned
SELECT TOP 10 * FROM Staging_Financials WHERE Amount < 0;

-- C8) IRON (half-yearly). Expected: only June 30 and December 31 dates
SELECT DISTINCT EndOfQuarter FROM Fact_Financials
WHERE Company = 'IRON' ORDER BY EndOfQuarter;

-- C9) AMOC periods. Expected: real quarters plus one 'n/a' group
SELECT Period, COUNT(*) AS Rows_Count
FROM Staging_Financials
WHERE Company = 'AMOC'
GROUP BY Period ORDER BY Period;

-- C10) Blank cells are NOT stored as 0. Expected: 2025-06-30 is absent for AALR
SELECT EndOfQuarter, Amount
FROM Fact_Financials
WHERE Company = 'AALR' AND Line_Item = 'Cash & Equivalents'
ORDER BY EndOfQuarter DESC;

-- C11) Dimensions. Expected: Companies = 212, 3 statement types, no NULL calendar date
SELECT COUNT(*) AS Accounts      FROM DimAccount;
SELECT COUNT(*) AS Companies     FROM DimCompany;
SELECT * FROM DimStatement;
SELECT COUNT(*) AS Calendar_Rows FROM DimCalendar;
SELECT * FROM DimCalendar ORDER BY EndOfQuarter;

-- C12) Compare a few quarters of one company with its stockanalysis.com page (change the ticker)
SELECT TOP 8 * FROM Fact_Metrics WHERE Company = 'JUFO' ORDER BY EndOfQuarter DESC;

-- C13) How often is each KPI missing? (banks and insurers will be missing industrial items)
SELECT COUNT(*) AS Company_Quarters,
       SUM(CASE WHEN Revenue          IS NULL THEN 1 ELSE 0 END) AS No_Revenue,
       SUM(CASE WHEN Gross_Profit     IS NULL THEN 1 ELSE 0 END) AS No_Gross_Profit,
       SUM(CASE WHEN EBITDA           IS NULL THEN 1 ELSE 0 END) AS No_EBITDA,
       SUM(CASE WHEN Net_Income       IS NULL THEN 1 ELSE 0 END) AS No_Net_Income,
       SUM(CASE WHEN Free_Cash_Flow   IS NULL THEN 1 ELSE 0 END) AS No_FCF,
       SUM(CASE WHEN Net_Debt         IS NULL THEN 1 ELSE 0 END) AS No_Net_Debt,
       SUM(CASE WHEN Total_Equity     IS NULL THEN 1 ELSE 0 END) AS No_Equity
FROM Fact_Metrics;

-- C14) Accounting check from the brief: Assets = Liabilities + Equity (tolerance 1%)
SELECT COUNT(*) AS Checked,
       SUM(CASE WHEN ABS(Total_Assets - Total_Liabilities - Total_Equity) > 0.01 * ABS(Total_Assets) THEN 1 ELSE 0 END) AS Not_Balanced
FROM Fact_Metrics
WHERE Total_Assets IS NOT NULL AND Total_Liabilities IS NOT NULL AND Total_Equity IS NOT NULL;

-- C15) One row per company per period (must return no rows)
SELECT Company, EndOfQuarter, COUNT(*) AS Dupes
FROM Fact_Metrics GROUP BY Company, EndOfQuarter HAVING COUNT(*) > 1;

-- C16) P&L bridge: Revenue - Total_Cost - Interest - Tax + Other = Net Income (Bridge_Diff must be 0)
SELECT TOP 8 EndOfQuarter, Revenue, COGS, Opex, Total_Cost, Interest_Cost, Income_Tax, Other_Items, Net_Income,
       Revenue - Total_Cost - COALESCE(Interest_Cost, 0) - COALESCE(Income_Tax, 0) + Other_Items - Net_Income AS Bridge_Diff
FROM Fact_Metrics
WHERE Company = 'SWDY' AND Total_Cost IS NOT NULL
ORDER BY EndOfQuarter DESC;