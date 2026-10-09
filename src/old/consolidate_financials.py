import csv
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FINANCIALS_FOLDER = PROJECT_ROOT / "data" / "raw" / "financials"
RAW_FOLDER = PROJECT_ROOT / "data" / "raw"
OUTPUT_FOLDER = PROJECT_ROOT / "data" / "processed"


def load_company_names():
    company_names = {}
    companies_file = RAW_FOLDER / "egx_companies.csv"

    if companies_file.exists():
        with companies_file.open(encoding="utf-8-sig", newline="") as source:
            for row in csv.DictReader(source):
                symbol = row.get("Symbol", "")
                name = row.get("Company Name", "")
                if symbol and name:
                    company_names[symbol] = name

    mapping_file = RAW_FOLDER / "recovered_company_mapping.csv"
    if mapping_file.exists():
        with mapping_file.open(encoding="utf-8-sig", newline="") as source:
            for row in csv.DictReader(source):
                symbol = row["Recovered_Symbol"]
                name = row["Company_Name"]
                if symbol and name and symbol not in company_names:
                    company_names[symbol] = name

    return company_names


def main():
    OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)
    company_names = load_company_names()
    files_by_metric = {}
    columns_by_metric = {}

    for source_file in sorted(FINANCIALS_FOLDER.glob("*.csv")):
        if "_" not in source_file.stem:
            print(f"Skipping unrecognized filename: {source_file.name}")
            continue

        symbol, metric = source_file.stem.split("_", maxsplit=1)
        with source_file.open(encoding="utf-8-sig", newline="") as source:
            reader = csv.DictReader(source)
            if not reader.fieldnames:
                print(f"Skipping empty file: {source_file.name}")
                continue

            metric_columns = columns_by_metric.setdefault(
                metric, ["Symbol", "Company"]
            )
            for column in reader.fieldnames:
                if column not in metric_columns:
                    metric_columns.append(column)

            metric_rows = files_by_metric.setdefault(metric, [])
            for row in reader:
                row["Symbol"] = symbol
                row["Company"] = company_names.get(symbol, "")
                metric_rows.append(row)

    for metric, combined_rows in sorted(files_by_metric.items()):
        output_file = OUTPUT_FOLDER / f"{metric}.csv"
        with output_file.open("w", encoding="utf-8-sig", newline="") as output:
            writer = csv.DictWriter(
                output,
                fieldnames=columns_by_metric[metric],
                extrasaction="ignore",
            )
            writer.writeheader()
            writer.writerows(combined_rows)
        print(
            f"{metric}: appended {len(combined_rows)} rows "
            f"from {sum(1 for path in FINANCIALS_FOLDER.glob(f'*_{metric}.csv'))} files "
            f"-> {output_file.relative_to(PROJECT_ROOT)}"
        )


if __name__ == "__main__":
    main()