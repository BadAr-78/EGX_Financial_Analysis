/* =====================================================================
   EGX FINANCIAL ANALYSIS - FULL SQL MODEL (pages 1-6)      DB: EGX_Data      SQL Server
   BEGINNER-FRIENDLY VERSION: only SELECT / FROM / JOIN / WHERE / GROUP BY / CASE / COALESCE.
   No CTEs (WITH ...). The long calculation is split into 3 small views you can read one by one.

   HOW TO RUN
     1. Open SSMS, connect to localhost.
     2. File > Open > this file, press Execute (F5). Run the WHOLE file; it is safe to run again.
        ("CREATE OR ALTER VIEW" = create the view, or replace it if it already exists.)
     3. Then run the CHECKS at the bottom one at a time (select a query, press F5).
     4. In Power BI press Refresh.

   WORDS USED IN THIS FILE
     VIEW   = a saved SELECT query. Power BI reads a view like a table.
     GO     = tells SSMS "send everything above to the server now". Not part of SQL itself.
     CASE   = IF / ELSE inside a query.
     COALESCE(a, b, c) = take the first value that is not empty (NULL).
     NULL   = "no data". NULL is NOT zero. (Banks have no "Cost of Revenue", so it stays NULL.)
     MAX(CASE WHEN Line_Item = 'X' THEN Amount END) = "give me the Amount of line X".
                  This turns many rows (one per line item) into ONE row with one column per line item.

   THE SOURCE TABLE
     Staging_Financials(Line_Order, Company, Statement, Line_Item, Period, Amount)
     Filled by egx_scraper_full.py from stockanalysis.com ('-' cells are dropped, not turned into 0).

   WHAT THIS FILE CREATES (in this order)
     1. DimAccount            one row per statement line (a list of all line items)
     2. Fact_Financials       every statement line, per company, per quarter     -> P&L matrix (page 2)
     3. DimCompany            list of companies                                  -> slicers / page 6
     4. DimStatement          list of the 3 statements
     5. DimCalendar           list of quarter-end dates (Year, Quarter, Quarter_Year such as 2024_4)
     6. Metrics_Step1_Pivot   one row per company per quarter, raw columns (one per line item we need)
     7. Metrics_Step2_Clean   picks the right column when companies name a line differently
     8. Fact_Metrics          final KPI table (EBITDA, Net_Debt, Free_Cash_Flow ...) -> every KPI / chart

   WHICH Fact_Metrics COLUMNS FEED WHICH PAGE
     1 Overview            Revenue, Gross_Profit, Operating_Income, EBITDA, Net_Income, Operating_Cash_Flow,
                           Capex, Free_Cash_Flow, Net_Debt, Total_Equity
     2 Profit & Loss       Revenue, COGS, Opex, Total_Cost, Interest_Cost, Income_Tax, Other_Items,
                           Gross_Profit, Operating_Income, Net_Income  (+ Fact_Financials for the matrix)
     3 Balance Sheet       Total_Assets, Total_Liabilities, Total_Equity, Current_Liabilities, Total_Debt,
                           ST_Debt, LT_Debt, PPE, Inventory, Receivables, Cash_And_STI, Payables
     4 Liquidity/Leverage  Current_Assets, Current_Liabilities, Cash_And_STI, Receivables, Total_Debt,
                           Total_Equity, Net_Debt, EBITDA, Operating_Income, Interest_Cost
     5 Working Capital     Receivables, Inventory, Payables, Revenue, COGS, Total_Assets, PPE
     6 Compare Companies   same columns, company by company (no extra SQL)

   DATA CAVEATS
     - Banks/insurers lack industrial lines (COGS, Inventory...) -> those columns stay NULL.
     - Some companies have fiscal years not ending in December, so quarter dates can differ from the calendar.
     - IRON is half-yearly (H1 -> 30 June, H2 -> 31 December). AMOC period 'n/a' is dropped.
       AALR has missing quarters (kept blank, never 0).
     - Other_Items is a balancing item so the P&L waterfall ends exactly at Net_Income. Watch its size.
     - ST_Debt = short-term debt + short-term borrowings + current long-term debt + current leases
       LT_Debt = long-term debt + long-term leases      Total_Debt = ST_Debt + LT_Debt
   ===================================================================== */

USE EGX_Data;
GO

-- =====================================================================
-- 1) DimAccount : one row per statement line
-- ROW_NUMBER() just numbers the rows 1, 2, 3... in the order we ask for (FinanceIndex).
-- Account_Label = Line_Item + [IS]/[BS]/[CF], so it is unique and Power BI can
-- "Sort by column": Account_Label -> FinanceIndex.
-- =====================================================================
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

-- =====================================================================
-- 2) Fact_Financials : every line, per company, per quarter
-- Period text -> a real date:   Q1 -> 31 Mar,  Q2 -> 30 Jun,  Q3 -> 30 Sep,  Q4 -> 31 Dec
--                               H1 -> 30 Jun,  H2 -> 31 Dec   (IRON is half-yearly)
-- Anything else (like 'n/a') is removed by the WHERE.
-- Dates are written as yyyymmdd (e.g. 20240331), which SQL Server always understands.
-- =====================================================================
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
    CASE LEFT(s.Period, 2)
        WHEN 'Q1' THEN CAST(RIGHT(s.Period, 4) + '0331' AS DATE)
        WHEN 'Q2' THEN CAST(RIGHT(s.Period, 4) + '0630' AS DATE)
        WHEN 'Q3' THEN CAST(RIGHT(s.Period, 4) + '0930' AS DATE)
        WHEN 'Q4' THEN CAST(RIGHT(s.Period, 4) + '1231' AS DATE)
        WHEN 'H1' THEN CAST(RIGHT(s.Period, 4) + '0630' AS DATE)
        WHEN 'H2' THEN CAST(RIGHT(s.Period, 4) + '1231' AS DATE)
    END AS EndOfQuarter,
    s.Amount
FROM Staging_Financials s
JOIN DimAccount a
  ON a.Statement = s.Statement
 AND a.Line_Item = s.Line_Item
WHERE LEFT(s.Period, 2) IN ('Q1', 'Q2', 'Q3', 'Q4', 'H1', 'H2')
  AND LEN(s.Period) = 7;          -- 'Q1 2024' has 7 characters; this drops junk such as 'n/a'
GO

-- =====================================================================
-- 3) DimCompany
-- =====================================================================
CREATE OR ALTER VIEW DimCompany AS
SELECT DISTINCT Company
FROM Fact_Financials;
GO

-- =====================================================================
-- 4) DimStatement
-- =====================================================================
CREATE OR ALTER VIEW DimStatement AS
SELECT DISTINCT Statement_Type
FROM Fact_Financials;
GO

-- =====================================================================
-- 5) DimCalendar : one row per quarter-end date
-- =====================================================================
CREATE OR ALTER VIEW DimCalendar AS
SELECT DISTINCT
    EndOfQuarter,
    YEAR(EndOfQuarter)                AS [Year],
    DATEPART(QUARTER, EndOfQuarter)   AS [Quarter],
    CONCAT(YEAR(EndOfQuarter), '_', DATEPART(QUARTER, EndOfQuarter)) AS Quarter_Year
FROM Fact_Financials
WHERE EndOfQuarter IS NOT NULL;
GO

-- =====================================================================
-- 6) Metrics_Step1_Pivot : ONE row per company per quarter.
-- Each column below = "the Amount of one line item". Several columns can mean the same
-- thing because companies name lines differently (for example 'Total Revenue' / 'Revenue').
-- Step 2 picks the one that has data.
-- Income statement columns start with is_, cash flow with cf_, balance sheet with bs_.
-- =====================================================================
CREATE OR ALTER VIEW Metrics_Step1_Pivot AS
SELECT
    Company,
    EndOfQuarter,

    -- ---------- Income statement ----------
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Total Revenue'                THEN Amount END) AS is_total_revenue,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Revenue'                      THEN Amount END) AS is_revenue,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Revenues Before Loan Losses' THEN Amount END) AS is_rev_bll,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Revenue Before Loan Losses'  THEN Amount END) AS is_rev_bll2,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Operating Revenue'           THEN Amount END) AS is_op_revenue,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Cost of Revenue'             THEN Amount END) AS is_cogs,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Gross Profit'                THEN Amount END) AS is_gross_profit,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Operating Income'            THEN Amount END) AS is_op_income,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Depreciation & Amortization' THEN Amount END) AS is_da,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Interest Expense'            THEN Amount END) AS is_interest_exp,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Pretax Income'               THEN Amount END) AS is_pretax,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Income Tax Expense'          THEN Amount END) AS is_tax,
    MAX(CASE WHEN Statement_Type = 'Income_Statement' AND Line_Item = 'Net Income'                  THEN Amount END) AS is_net_income,

    -- ---------- Cash flow ----------
    MAX(CASE WHEN Statement_Type = 'Cash_Flow' AND Line_Item = 'Depreciation & Amortization, Total' THEN Amount END) AS cf_da_total,
    MAX(CASE WHEN Statement_Type = 'Cash_Flow' AND Line_Item = 'Depreciation & Amortization'        THEN Amount END) AS cf_da,
    MAX(CASE WHEN Statement_Type = 'Cash_Flow' AND Line_Item = 'Operating Cash Flow'                THEN Amount END) AS cf_ocf,
    MAX(CASE WHEN Statement_Type = 'Cash_Flow' AND Line_Item = 'Capital Expenditures'                THEN Amount END) AS cf_capex,

    -- ---------- Balance sheet ----------
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Total Assets'                    THEN Amount END) AS bs_assets,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Total Liabilities'               THEN Amount END) AS bs_liab,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Shareholders'' Equity'           THEN Amount END) AS bs_equity,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Total Common Equity'             THEN Amount END) AS bs_common_equity,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Total Current Assets'            THEN Amount END) AS bs_cur_assets,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Total Current Liabilities'       THEN Amount END) AS bs_cur_liab,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Cash & Equivalents'              THEN Amount END) AS bs_cash,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Short-Term Investments'          THEN Amount END) AS bs_sti,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Cash & Short-Term Investments'   THEN Amount END) AS bs_cash_sti,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Short-Term Debt'                 THEN Amount END) AS bs_st_debt,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Short-Term Borrowings'           THEN Amount END) AS bs_st_borrow,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Current Portion of Long-Term Debt' THEN Amount END) AS bs_cur_ltd,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Current Portion of Leases'       THEN Amount END) AS bs_cur_leases,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Long-Term Debt'                  THEN Amount END) AS bs_lt_debt,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Long-Term Leases'                THEN Amount END) AS bs_lt_leases,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Inventory'                       THEN Amount END) AS bs_inventory,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Accounts Receivable'             THEN Amount END) AS bs_ar,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Receivables'                     THEN Amount END) AS bs_receivables,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Accounts Payable'                THEN Amount END) AS bs_ap,
    MAX(CASE WHEN Statement_Type = 'Balance_Sheet' AND Line_Item = 'Property, Plant & Equipment'     THEN Amount END) AS bs_ppe
FROM Fact_Financials
WHERE EndOfQuarter IS NOT NULL
GROUP BY Company, EndOfQuarter;
GO

-- =====================================================================
-- 7) Metrics_Step2_Clean : choose one clean column per KPI.
-- COALESCE(a, b, c) = use a; if a is empty use b; if b is empty use c.
-- Only simple choices here. The maths (EBITDA, Net_Debt ...) comes in step 3.
-- =====================================================================
CREATE OR ALTER VIEW Metrics_Step2_Clean AS
SELECT
    Company,
    EndOfQuarter,

    -- Revenue: first non-empty name wins
    COALESCE(is_total_revenue, is_revenue, is_rev_bll, is_rev_bll2, is_op_revenue) AS Revenue,

    -- Cost of revenue as a positive number (ABS removes the minus sign)
    ABS(is_cogs) AS COGS,

    -- Gross profit: use the reported line; if missing, calculate Revenue - COGS
    COALESCE(
        is_gross_profit,
        CASE WHEN COALESCE(is_total_revenue, is_revenue) IS NOT NULL AND is_cogs IS NOT NULL
             THEN COALESCE(is_total_revenue, is_revenue) - ABS(is_cogs) END
    ) AS Gross_Profit,

    is_op_income  AS Operating_Income,
    COALESCE(cf_da_total, cf_da, is_da) AS DA,        -- depreciation & amortization
    is_interest_exp AS Interest_Expense,
    is_pretax       AS Pretax_Income,
    is_tax          AS Income_Tax,
    is_net_income   AS Net_Income,

    -- Cash flow
    cf_ocf   AS Operating_Cash_Flow,
    cf_capex AS Capex,

    -- Balance sheet (closing values)
    bs_assets AS Total_Assets,
    bs_liab   AS Total_Liabilities,
    COALESCE(bs_equity, bs_common_equity) AS Total_Equity,
    bs_cur_assets AS Current_Assets,
    bs_cur_liab   AS Current_Liabilities,

    -- Cash: use "Cash & Short-Term Investments"; if missing add cash + short-term investments.
    -- Only when the company has a balance sheet at all (bs_assets is not empty).
    CASE WHEN bs_assets IS NOT NULL
         THEN COALESCE(bs_cash_sti, COALESCE(bs_cash, 0) + COALESCE(bs_sti, 0))
    END AS Cash_And_STI,

    -- Debt pieces. COALESCE(x, 0) means "treat an empty line as 0 when adding".
    CASE WHEN bs_assets IS NOT NULL
         THEN COALESCE(bs_st_debt, 0) + COALESCE(bs_st_borrow, 0)
            + COALESCE(bs_cur_ltd, 0) + COALESCE(bs_cur_leases, 0)
    END AS ST_Debt,

    CASE WHEN bs_assets IS NOT NULL
         THEN COALESCE(bs_lt_debt, 0) + COALESCE(bs_lt_leases, 0)
    END AS LT_Debt,

    bs_inventory AS Inventory,
    COALESCE(bs_ar, bs_receivables) AS Receivables,
    bs_ap  AS Payables,
    bs_ppe AS PPE
FROM Metrics_Step1_Pivot;
GO

-- =====================================================================
-- 8) Fact_Metrics : the final table Power BI reads.
-- Adds the calculated columns. Every calculation has a short note.
-- =====================================================================
CREATE OR ALTER VIEW Fact_Metrics AS
SELECT
    Company,
    EndOfQuarter,

    -- ---------- Income statement ----------
    Revenue,
    COGS,
    Gross_Profit,
    Operating_Income,
    DA,

    -- EBITDA = Operating income + depreciation (ABS in case the sign is negative)
    CASE WHEN Operating_Income IS NOT NULL AND DA IS NOT NULL
         THEN Operating_Income + ABS(DA) END AS EBITDA,

    Interest_Expense,
    Pretax_Income,
    Income_Tax,
    Net_Income,

    -- Interest as a positive cost
    ABS(Interest_Expense) AS Interest_Cost,

    -- Opex = costs between Gross Profit and Operating Income
    CASE WHEN Gross_Profit IS NOT NULL AND Operating_Income IS NOT NULL
         THEN Gross_Profit - Operating_Income END AS Opex,

    -- Total cost = everything between Revenue and Operating Income
    CASE WHEN Revenue IS NOT NULL AND Operating_Income IS NOT NULL
         THEN Revenue - Operating_Income END AS Total_Cost,

    -- Other_Items = what is left so the waterfall ends exactly at Net Income
    -- (non-operating income, unusual items, minority interest ...)
    CASE WHEN Operating_Income IS NOT NULL AND Net_Income IS NOT NULL
         THEN Net_Income - (Operating_Income - ABS(COALESCE(Interest_Expense, 0)) - COALESCE(Income_Tax, 0))
    END AS Other_Items,

    -- ---------- Cash flow ----------
    Operating_Cash_Flow,
    Capex,

    -- Free cash flow = operating cash flow - capital spending
    CASE WHEN Operating_Cash_Flow IS NOT NULL
         THEN Operating_Cash_Flow - ABS(COALESCE(Capex, 0)) END AS Free_Cash_Flow,

    -- ---------- Balance sheet ----------
    Total_Assets,
    Total_Liabilities,
    Total_Equity,
    Current_Assets,
    Current_Liabilities,
    Cash_And_STI,

    -- Total debt = short-term debt + long-term debt
    CASE WHEN ST_Debt IS NOT NULL AND LT_Debt IS NOT NULL
         THEN ST_Debt + LT_Debt END AS Total_Debt,

    -- Net debt = total debt - cash
    CASE WHEN ST_Debt IS NOT NULL AND LT_Debt IS NOT NULL
         THEN ST_Debt + LT_Debt - COALESCE(Cash_And_STI, 0) END AS Net_Debt,

    Inventory,
    Receivables,
    Payables,
    PPE,
    ST_Debt,
    LT_Debt
FROM Metrics_Step2_Clean;
GO


-- =====================================================================
-- CHECKS. Select ONE query (from its comment down to the semicolon) and press F5.
-- =====================================================================

-- C1) Overall health.  Expected: Companies = 212, Zero_Rows small (about 3,670), Null_Dates = 0
SELECT
    (SELECT COUNT(DISTINCT Company) FROM Staging_Financials)           AS Companies,
    (SELECT COUNT(*) FROM Staging_Financials)                          AS Total_Rows,
    (SELECT COUNT(*) FROM Staging_Financials WHERE Amount = 0)         AS Zero_Rows,
    (SELECT COUNT(*) FROM Fact_Financials WHERE EndOfQuarter IS NULL)  AS Null_Dates;

-- C2) Fact health.  Expected: Missing_Account = 0, Null_Dates = 0
SELECT COUNT(*) AS Fact_Rows,
       SUM(CASE WHEN FinanceIndex IS NULL THEN 1 ELSE 0 END) AS Missing_Account,
       SUM(CASE WHEN EndOfQuarter IS NULL THEN 1 ELSE 0 END) AS Null_Dates
FROM Fact_Financials;

-- C3) Rows per company and statement
SELECT Company, Statement, COUNT(*) AS Rows_Count
FROM Staging_Financials
GROUP BY Company, Statement
ORDER BY Company, Statement;

-- C4) Companies missing a statement.  Expected: no rows
SELECT Company, COUNT(DISTINCT Statement) AS Statements_Count
FROM Staging_Financials
GROUP BY Company
HAVING COUNT(DISTINCT Statement) < 3;

-- C5) Period texts that are NOT quarterly (Q1..Q4).  Expected: only H1/H2 (IRON) and 'n/a' (AMOC)
SELECT Period, Company, Statement, COUNT(*) AS Rows_Count
FROM Staging_Financials
WHERE LEFT(Period, 2) NOT IN ('Q1', 'Q2', 'Q3', 'Q4')
GROUP BY Period, Company, Statement
ORDER BY Rows_Count DESC;

-- C6) Periods dropped from Fact_Financials.  Expected: only 'n/a'
SELECT DISTINCT Period, Company
FROM Staging_Financials
WHERE LEFT(Period, 2) NOT IN ('Q1', 'Q2', 'Q3', 'Q4', 'H1', 'H2')
   OR LEN(Period) <> 7;

-- C7) Negative numbers are kept.  Expected: rows returned
SELECT TOP 10 * FROM Staging_Financials WHERE Amount < 0;

-- C8) IRON (half-yearly).  Expected: only 30 June and 31 December dates
SELECT DISTINCT EndOfQuarter
FROM Fact_Financials
WHERE Company = 'IRON'
ORDER BY EndOfQuarter;

-- C9) AMOC periods.  Expected: real quarters plus one 'n/a' group
SELECT Period, COUNT(*) AS Rows_Count
FROM Staging_Financials
WHERE Company = 'AMOC'
GROUP BY Period
ORDER BY Period;

-- C10) Blank cells are NOT stored as 0.  Expected: 2025-06-30 is missing for AALR
SELECT EndOfQuarter, Amount
FROM Fact_Financials
WHERE Company = 'AALR' AND Line_Item = 'Cash & Equivalents'
ORDER BY EndOfQuarter DESC;

-- C11) Dimensions.  Expected: 212 companies, 3 statement types, no NULL calendar date
SELECT COUNT(*) AS Accounts      FROM DimAccount;
SELECT COUNT(*) AS Companies     FROM DimCompany;
SELECT * FROM DimStatement;
SELECT COUNT(*) AS Calendar_Rows FROM DimCalendar;
SELECT * FROM DimCalendar ORDER BY EndOfQuarter;

-- C12) Compare a few quarters of one company with its stockanalysis.com page (change the ticker)
SELECT TOP 8 * FROM Fact_Metrics WHERE Company = 'JUFO' ORDER BY EndOfQuarter DESC;

-- C13) How often is each KPI missing?  (banks and insurers will miss industrial items)
SELECT COUNT(*) AS Company_Quarters,
       SUM(CASE WHEN Revenue        IS NULL THEN 1 ELSE 0 END) AS No_Revenue,
       SUM(CASE WHEN Gross_Profit   IS NULL THEN 1 ELSE 0 END) AS No_Gross_Profit,
       SUM(CASE WHEN EBITDA         IS NULL THEN 1 ELSE 0 END) AS No_EBITDA,
       SUM(CASE WHEN Net_Income     IS NULL THEN 1 ELSE 0 END) AS No_Net_Income,
       SUM(CASE WHEN Free_Cash_Flow IS NULL THEN 1 ELSE 0 END) AS No_FCF,
       SUM(CASE WHEN Net_Debt       IS NULL THEN 1 ELSE 0 END) AS No_Net_Debt,
       SUM(CASE WHEN Total_Equity   IS NULL THEN 1 ELSE 0 END) AS No_Equity
FROM Fact_Metrics;

-- C14) Accounting check from the brief: Assets = Liabilities + Equity (1% tolerance)
SELECT COUNT(*) AS Checked,
       SUM(CASE WHEN ABS(Total_Assets - Total_Liabilities - Total_Equity) > 0.01 * ABS(Total_Assets)
                THEN 1 ELSE 0 END) AS Not_Balanced
FROM Fact_Metrics
WHERE Total_Assets IS NOT NULL AND Total_Liabilities IS NOT NULL AND Total_Equity IS NOT NULL;

-- C15) One row per company per quarter.  Expected: no rows
SELECT Company, EndOfQuarter, COUNT(*) AS Dupes
FROM Fact_Metrics
GROUP BY Company, EndOfQuarter
HAVING COUNT(*) > 1;

-- C16) P&L bridge: Revenue - Total_Cost - Interest - Tax + Other = Net Income.  Bridge_Diff must be 0
SELECT TOP 8 EndOfQuarter, Revenue, COGS, Opex, Total_Cost, Interest_Cost, Income_Tax, Other_Items, Net_Income,
       Revenue - Total_Cost - COALESCE(Interest_Cost, 0) - COALESCE(Income_Tax, 0) + Other_Items - Net_Income AS Bridge_Diff
FROM Fact_Metrics
WHERE Company = 'SWDY' AND Total_Cost IS NOT NULL
ORDER BY EndOfQuarter DESC;

-- C17) Pages 3-6 columns.  Expected: PPE / ST_Debt / LT_Debt have numbers, Diff_Should_Be_0 = 0
SELECT TOP 10 Company, EndOfQuarter, Total_Assets, PPE, ST_Debt, LT_Debt, Total_Debt,
       Total_Debt - (ST_Debt + LT_Debt) AS Diff_Should_Be_0
FROM Fact_Metrics
WHERE Company = 'SWDY'
ORDER BY EndOfQuarter DESC;

-- C17b) Is the PP&E line name right?  Expected: 'Property, Plant & Equipment' with many companies
SELECT Line_Item, COUNT(DISTINCT Company) AS Companies
FROM Fact_Financials
WHERE Statement_Type = 'Balance_Sheet' AND Line_Item LIKE '%Property%'
GROUP BY Line_Item
ORDER BY Companies DESC;

-- C18) The simplified version gives the same answer as before for SWDY 2024.
--      Expected: Revenue 45,250 / 57,377 / 62,196 / 67,160 and Free_Cash_Flow sum = -4,343
SELECT EndOfQuarter, Revenue, Operating_Cash_Flow, Capex, Free_Cash_Flow
FROM Fact_Metrics
WHERE Company = 'SWDY' AND EndOfQuarter BETWEEN '20240101' AND '20241231'
ORDER BY EndOfQuarter;