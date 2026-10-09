import requests
from bs4 import BeautifulSoup
import pandas as pd

url = "https://stockanalysis.com/list/egyptian-stock-exchange/"

headers = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/154.0.0.0 Safari/537.36"
    )
}

response = requests.get(
    url,
    headers=headers,
    timeout=30
)

response.raise_for_status()

soup = BeautifulSoup(response.text, "html.parser")

table = soup.find("table")

rows = table.find_all("tr")

data = []

for row in rows:
    cells = row.find_all(["th", "td"])

    row_data = [
        cell.get_text(strip=True)
        for cell in cells
    ]

    if row_data:
        data.append(row_data)

df = pd.DataFrame(
    data[1:],
    columns=data[0]
)

print(df.head())
print("\nShape:", df.shape)
print("\nColumns:")
print(df.columns.tolist())

df.to_csv(
    "data/raw/egx_companies.csv",
    index=False
)

print("\nFile saved successfully!")