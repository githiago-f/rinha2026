import json

legit = 0
fraud = 0

with open("references.json", "r", encoding="utf-8") as f:
    full_file = json.load(f)

    for obj in full_file:
        label = obj["label"]

        if label == "legit":
            legit += 1
        elif label == "fraud":
            fraud += 1
        else:
            print("Label desconhecido:", label)

total = legit + fraud

print(f"Total: {total}")
print(f"Legit: {legit}")
print(f"Fraud: {fraud}")
print(f"Fraud rate: {fraud / total:.4f}")
print(f"Legit rate: {legit / total:.4f}")
