import pyodbc, urllib.parse
from sqlalchemy import create_engine, text

print("Drivers:", pyodbc.drivers())

server = 'localhost'
database = 'EGX_Data'

params = urllib.parse.quote_plus(
    f"DRIVER={{ODBC Driver 17 for SQL Server}};"
    f"SERVER={server};"
    f"DATABASE={database};"
    f"Trusted_Connection=yes;"
)
engine = create_engine(f"mssql+pyodbc:///?odbc_connect={params}")

with engine.connect() as conn:
    print(conn.execute(text("SELECT DB_NAME()")).scalar())