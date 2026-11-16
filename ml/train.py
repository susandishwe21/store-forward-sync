"""ML-2: train and compare connectivity success predictors (RQ2, RQ2b).

Reads  results/dataset.csv  (from: dart run packages/sf_harness/bin/simulate.dart --mode=dataset)
Writes results/model_metrics.csv, results/roc_calibration.png, ml/models/logreg.json
"""
import json
import pickle
from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # draw charts into files, no window
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.calibration import calibration_curve
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import brier_score_loss, log_loss, roc_auc_score, roc_curve
from sklearn.preprocessing import StandardScaler

ROOT = Path(__file__).resolve().parent.parent
FEATURES = [
    "hour_sin", "hour_cos", "bars", "min_since_success", "last_failed",
    "failures_in_a_row", "pending", "oldest_pending_min", "min_since_attempt",
]

# ── 1. Load, and split BY SEED: test weeks are never seen during training ──
data = pd.read_csv(ROOT / "results" / "dataset.csv")
train = data[data.seed <= 114]
valid = data[(data.seed >= 115) & (data.seed <= 117)]
test = data[data.seed >= 118]
print(f"rows: train {len(train)}, valid {len(valid)}, test {len(test)}")
print(f"success rate: train {train.success.mean():.3f}, test {test.success.mean():.3f}")

X_train, y_train = train[FEATURES].to_numpy(), train.success.to_numpy()
X_test, y_test = test[FEATURES].to_numpy(), test.success.to_numpy()

predictions, sizes = {}, {}

# Step 1a: always predict the average success rate.
predictions["base_rate"] = np.full(len(test), y_train.mean())
sizes["base_rate"] = 8

# Step 1b: success rate per number of signal bars (the "signal rule" as a probability).
by_bars = train.groupby("bars").success.mean()
predictions["bars_lookup"] = test.bars.map(by_bars).fillna(y_train.mean()).to_numpy()
sizes["bars_lookup"] = 8 * len(by_bars)

# Step 2: logistic regression on standardised features.
scaler = StandardScaler().fit(X_train)
logreg = LogisticRegression(max_iter=1000).fit(scaler.transform(X_train), y_train)
predictions["logistic_regression"] = logreg.predict_proba(scaler.transform(X_test))[:, 1]
sizes["logistic_regression"] = 8 * (3 * len(FEATURES) + 1)

# Step 3: histogram-based gradient boosting (same family as LightGBM).
gbm = HistGradientBoostingClassifier(
    max_iter=300, learning_rate=0.05, early_stopping=True, random_state=0)
gbm.fit(X_train, y_train)
predictions["gradient_boosting"] = gbm.predict_proba(X_test)[:, 1]
sizes["gradient_boosting"] = len(pickle.dumps(gbm))

# ── 2. Score every model on the same unseen test weeks ──
rows = []
for name, p in predictions.items():
    p = np.clip(p, 1e-6, 1 - 1e-6)
    rows.append({
        "model": name,
        "auc": roc_auc_score(y_test, p),
        "brier": brier_score_loss(y_test, p),
        "log_loss": log_loss(y_test, p),
        "size_bytes": sizes[name],
    })
metrics = pd.DataFrame(rows)
metrics.to_csv(ROOT / "results" / "model_metrics.csv", index=False)
print("\n" + metrics.to_string(index=False, float_format=lambda v: f"{v:.4f}"))

# ── 3. Which features matter? (logistic regression is explainable) ──
print("\nLogistic regression weights (+ = more likely to succeed):")
for name, weight in sorted(zip(FEATURES, logreg.coef_[0]), key=lambda t: -abs(t[1])):
    print(f"  {name:22s} {weight:+.3f}")

# ── 4. Charts for the paper: ROC and calibration ──
fig, (roc_ax, cal_ax) = plt.subplots(1, 2, figsize=(11, 4.5))
for name, p in predictions.items():
    if name == "base_rate":
        continue
    fpr, tpr, _ = roc_curve(y_test, p)
    roc_ax.plot(fpr, tpr, label=name)
    observed, predicted = calibration_curve(y_test, p, n_bins=10, strategy="uniform")
    cal_ax.plot(predicted, observed, marker="o", label=name)
for ax in (roc_ax, cal_ax):
    ax.plot([0, 1], [0, 1], "--", color="grey", linewidth=1)
    ax.legend()
roc_ax.set(title="ROC on unseen test weeks", xlabel="False positive rate", ylabel="True positive rate")
cal_ax.set(title="Calibration on unseen test weeks", xlabel="Predicted success probability",
           ylabel="Observed success rate")
fig.tight_layout()
fig.savefig(ROOT / "results" / "roc_calibration.png", dpi=150)

# ── 5. Export logistic regression for the Dart engine ──
model = {
    "features": FEATURES,
    "mean": scaler.mean_.tolist(),
    "scale": scaler.scale_.tolist(),
    "coef": logreg.coef_[0].tolist(),
    "intercept": float(logreg.intercept_[0]),
}
sample = X_test[0]
model["check"] = {
    "features": sample.tolist(),
    "probability": float(logreg.predict_proba(scaler.transform(sample.reshape(1, -1)))[0, 1]),
}
(ROOT / "ml" / "models" / "logreg.json").write_text(json.dumps(model, indent=2))
print("\nWrote results/model_metrics.csv, results/roc_calibration.png, ml/models/logreg.json")