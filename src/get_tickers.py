import io
import re
import sys

import pandas as pd
import requests

headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}

# You can pass the exact URL yourself:  python get_tickers.py https://stockanalysis.com/list/....
candidates = []
if len(sys.argv) > 1:
    candidates.append(sys.argv[1])
candidates += [
    "https://stockanalysis.com/list/egyptian-stock-exchange/",
    "https://stockanalysis.com/list/egypt-stock-exchange/",
    "https://stockanalysis.com/list/cairo-stock-exchange/",
    "https://stockanalysis.com/list/egx/",
    "https://stockanalysis.com/list/egypt/",
]

def try_url(url):
    r = requests.get(url, headers=headers, timeout=30)
    print(f"{r.status_code}  {url}")
    if r.status_code != 200:
        return None
    for t in pd.read_html(io.StringIO(r.text)):
        sym = [c for c in t.columns if "symbol" in str(c).lower()]
        if sym:
            return t[sym[0]]
    return None

series = None
for url in candidates:
    series = try_url(url)
    if series is not None:
        break

# Fallback: look for an Egypt link on the site's lists index
if series is None:
    print("\nSearching the site's lists index for an Egypt page...")
    for index_url in ["https://stockanalysis.com/list/", "https://stockanalysis.com/stocks/"]:
        r = requests.get(index_url, headers=headers, timeout=30)
        links = set(re.findall(r'href="(/[^"]*(?:egypt|egx|cairo)[^"]*)"', r.text, re.I))
        print(index_url, "->", links)
        for link in links:
            series = try_url("https://stockanalysis.com" + link)
            if series is not None:
                break
        if series is not None:
            break

if series is None:
    print("\nCould not find the list page automatically.")
    print("Open stockanalysis.com in your browser, find the Egypt stocks list,")
    print("then run:  python get_tickers.py <that-url>")
    sys.exit(1)

tickers = sorted(set(series.astype(str).str.strip().str.upper()))
with open("tickers.txt", "w") as f:
    f.write("\n".join(tickers))

print("\nNumber of tickers:", len(tickers))
print(tickers[:10])