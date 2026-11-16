"""ML-2, ladder step 4: a small GRU over the last K attempts (RQ2b).
Appends its scores to results/model_metrics.csv (run train.py first)."""
from pathlib import Path

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
from sklearn.metrics import brier_score_loss, log_loss, roc_auc_score

ROOT = Path(__file__).resolve().parent.parent
FEATURES = [
    "hour_sin", "hour_cos", "bars", "min_since_success", "last_failed",
    "failures_in_a_row", "pending", "oldest_pending_min", "min_since_attempt",
]
K = 8  # how many recent attempts the GRU looks at
torch.manual_seed(0)
np.random.seed(0)

data = pd.read_csv(ROOT / "results" / "dataset.csv")
train = data[data.seed <= 114]
valid = data[(data.seed >= 115) & (data.seed <= 117)]
test = data[data.seed >= 118]
mean = train[FEATURES].to_numpy().mean(axis=0)
std = train[FEATURES].to_numpy().std(axis=0) + 1e-9


def sequences(frame):
    """For each attempt: the features of it and the K-1 attempts before it (same week only)."""
    xs, ys = [], []
    for _, week in frame.groupby("seed", sort=False):
        f = ((week[FEATURES].to_numpy() - mean) / std).astype(np.float32)
        f = np.vstack([np.zeros((K - 1, f.shape[1]), np.float32), f])  # pad the start
        y = week.success.to_numpy().astype(np.float32)
        for i in range(len(week)):
            xs.append(f[i:i + K])
            ys.append(y[i])
    return torch.tensor(np.array(xs)), torch.tensor(np.array(ys))


class SuccessGRU(nn.Module):
    def __init__(self, inputs, hidden=16):
        super().__init__()
        self.gru = nn.GRU(inputs, hidden, batch_first=True)
        self.out = nn.Linear(hidden, 1)

    def forward(self, x):
        _, h = self.gru(x)
        return self.out(h[-1]).squeeze(-1)  # a logit; sigmoid gives the probability


X_tr, y_tr = sequences(train)
X_va, y_va = sequences(valid)
X_te, y_te = sequences(test)
model = SuccessGRU(len(FEATURES))
optimiser = torch.optim.Adam(model.parameters(), lr=1e-3)
loss_fn = nn.BCEWithLogitsLoss()

best, best_state, patience = float("inf"), None, 0
for epoch in range(40):
    model.train()
    order = torch.randperm(len(X_tr))
    for start in range(0, len(order), 256):
        batch = order[start:start + 256]
        optimiser.zero_grad()
        loss = loss_fn(model(X_tr[batch]), y_tr[batch])
        loss.backward()
        optimiser.step()
    model.eval()
    with torch.no_grad():
        valid_loss = loss_fn(model(X_va), y_va).item()
    print(f"epoch {epoch + 1:2d}  validation loss {valid_loss:.4f}")
    if valid_loss < best - 1e-4:
        best, best_state, patience = valid_loss, {k: v.clone() for k, v in model.state_dict().items()}, 0
    else:
        patience += 1
        if patience >= 5:  # early stopping: no improvement for 5 epochs
            break

model.load_state_dict(best_state)
model.eval()
with torch.no_grad():
    p = torch.sigmoid(model(X_te)).numpy().clip(1e-6, 1 - 1e-6)
y = y_te.numpy()
params = sum(t.numel() for t in model.parameters())
row = {"model": "gru", "auc": roc_auc_score(y, p), "brier": brier_score_loss(y, p),
       "log_loss": log_loss(y, p), "size_bytes": 4 * params}

metrics = pd.read_csv(ROOT / "results" / "model_metrics.csv")
metrics = pd.concat([metrics[metrics.model != "gru"], pd.DataFrame([row])], ignore_index=True)
metrics.to_csv(ROOT / "results" / "model_metrics.csv", index=False)
print("\n" + metrics.to_string(index=False, float_format=lambda v: f"{v:.4f}"))