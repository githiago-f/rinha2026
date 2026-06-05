#!/usr/bin/env python3.14
# this is a benchmark based on test data
# for debug purposes
import json
import sys
from pathlib import Path

if len(sys.argv) != 3:
    print(f"usage: {sys.argv[0]} input.json benchmark.ndjson")
    sys.exit(1)

input_file = Path(sys.argv[1])
output_file = Path(sys.argv[2])

with input_file.open("r", encoding="utf-8") as f:
    root = json.load(f)

entries = root.get("entries")
if not isinstance(entries, list):
    raise ValueError("entries not found")

count = 0

with output_file.open("w", encoding="utf-8") as out:
    for entry in entries:
        request = entry.get("request")
        approved = entry.get("expected_approved")
        fraud_score = entry.get("expected_fraud_score")

        record = {
            "request": request,
            "approved": approved,
            "fraud_score": fraud_score,
        }

        out.write(
            json.dumps(
                record,
                separators=(",", ":"),
                ensure_ascii=False,
            )
        )
        out.write("\n")

        count += 1

print(f"written {count} records to {output_file}")
