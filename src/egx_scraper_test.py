import io
import sys
import time
import urllib.parse

import pandas as pd
import requests
from sqlalchemy import create_engine, text

# ==========================================
# STEP 1: SET UP COMPANIES AND PERIOD
# ==========================================
# TEST MODE: 3 companies only. In the full run, paste your full 211-ticker list here.
companies_list = ["SWDY", "TMGH", "ETEL"]

statements = ["income-statement", "balance-sheet", "cash-flow-statement"]

period_input = input("Enter period (1: yearly, 2: quarterly, 3: trailing): ")
if period_input == "2":
    period_url = "?p=quarterly"
elif period_input == "3":
    period_url = "?p=trailing"
else:
    period_url = ""

headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}

# ==========================================
# STEP 2: CONNECT TO DATABASE ONCE AT THE START
# ==========================================
server = "localhost"
database = "EGX_Data"

print(f"\nConnecting to SQL Server database '{database}'...")
try:
    params = urllib.parse.quote_plus(
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={server};"
        f"DATABASE={database};"
        f"Trusted_Connection=yes;"
    )
    engine = create_engine(f"mssql+pyodbc:///?odbc_connect={params}")

    # FIX 3: empty the staging table so re-runs don't duplicate rows
    with engine.begin() as connection:
        connection.execute(text(
            "IF OBJECT_ID('Staging_Financials', 'U') IS NOT NULL "
            "DELETE FROM Staging_Financials"
        ))
    print("Database connection successful (staging table cleared)!\n")

except Exception as e:
    print(f"Failed to connect to SQL Server. Error: {e}")
    sys.exit()

# ==========================================
# STEP 3: SCRAPE, CLEAN, AND SAVE CONTINUOUSLY
# ==========================================
print(f"Starting download and database insertion for {len(companies_list)} companies...\n")

i = 1
total_requests = len(companies_list) * len(statements)

for company in companies_list:
    for statement in statements:
        url = f"https://stockanalysis.com/quote/egx/{company}/financials/{statement}/{period_url}"
        print(f"[{i}/{total_requests}] Fetching: {company} - {statement}...", end=" ")

        try:
            # 1. Download the webpage (FIX 1: timeout + status check)
            response = requests.get(url, headers=headers, timeout=30)
            response.raise_for_status()
            all_tables = pd.read_html(io.StringIO(response.text))

            if statement == "income-statement":
                tables_to_combine = [all_tables[0]]
            else:  # balance-sheet and cash-flow-statement
                tables_to_combine = all_tables[0:3]

            # 2. Standardize headers
            cleaned_tables = []
            for table in tables_to_combine:
                if isinstance(table.columns, pd.MultiIndex):
                    table.columns = table.columns.get_level_values(0)
                cols = list(table.columns)
                cols[0] = "Line_Item"
                table.columns = cols
                cleaned_tables.append(table)

            # 3. Combine tables and remove duplicate columns
            df = pd.concat(cleaned_tables, ignore_index=True)
            df = df.loc[:, ~df.columns.duplicated()]
            df = df.dropna(how="all").drop_duplicates()

            df.insert(0, "Line_Order", range(1, len(df) + 1))
            df.insert(1, "Company", company.upper())
            df.insert(2, "Statement", statement)

            # 4. Unpivot (melt)
            melted_df = df.melt(
                id_vars=["Line_Order", "Company", "Statement", "Line_Item"],
                var_name="Period",
                value_name="Amount",
            )

            melted_df["Period"] = melted_df["Period"].astype(str)

            # FIX 2: only cells that are exactly "-" become 0; negatives stay negative
            amount = melted_df["Amount"].astype(str).str.replace(",", "", regex=False)
            melted_df["Amount"] = amount.replace("-", "0")
            melted_df["Amount"] = pd.to_numeric(melted_df["Amount"], errors="coerce")
            melted_df = melted_df.dropna(subset=["Amount"])

            melted_df = melted_df.sort_values(
                by=["Line_Order", "Period"], ascending=[True, False]
            )

            # 5. Insert directly to database
            if not melted_df.empty:
                melted_df.to_sql(
                    name="Staging_Financials",
                    con=engine,
                    if_exists="append",
                    index=False,
                )
                print("Saved to DB.")
            else:
                print("No valid data to save.")

        except Exception as e:
            # FIX 4: show the real reason for the failure
            print(f"\n{company} - {statement} failed: {e}")

        i += 1
        time.sleep(1)

print("\nAll processes completed!")