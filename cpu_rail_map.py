import pandas as pd
from pyexcel.cookbook import merge_all_to_a_book
import pyexcel_xlsx  # ensure Excel support
import glob
import matplotlib.pyplot as plt 

# Load your logged data
df = pd.read_csv("./reg_cpu_map_manual.csv")


merge_all_to_a_book(glob.glob("./reg_cpu_map_manual.csv"), "./reg_cpu_map_manual.xlsx")

# Select all regulator columns
regs = [c for c in df.columns if c.startswith("regulator")]

print(regs)

# Convert timestamp to relative seconds (optional, makes the x-axis cleaner)
df["time"] = df["ts"] - df["ts"].min()

# Make one unified plot
plt.figure(figsize=(12, 6))
for r in regs:
    plt.plot(df["time"], df[r] / 1e6, label=r, linewidth=1.5)

plt.xlabel("Time (s)")
plt.ylabel("Voltage (V)")
plt.title("CPU Regulator Voltages Over Time (All Rails)")
plt.legend(loc="upper right", fontsize=8, ncol=2)
plt.grid(True, linestyle="--", alpha=0.4)

# Highlight phase changes (optional)
for i, phase in enumerate(df["phase"].unique()):
    phase_points = df[df["phase"] == phase]["time"]
    if not phase_points.empty:
        mid = phase_points.mean()
        plt.axvline(mid, color="gray", linestyle="--", alpha=0.2)
        plt.text(mid, plt.ylim()[1]*0.95, phase, rotation=90,
                 ha="center", va="top", fontsize=8, color="gray")

plt.tight_layout()
plt.show()


for r in regs:
    subset = df[df["phase"].isin(["idle","little","big","prime"])]
    print(r, "min:", subset[r].min()/1e6, "V", "max:", subset[r].max()/1e6, "V")

for phase in ["little","big","prime"]:
    tmp = df[df["phase"] == phase]
    tmp = tmp.groupby("cpu0_khz" if phase=="little" else "cpu4_khz" if phase=="big" else "cpu7_khz")[regs].mean()
    print(phase)
    print(tmp/tmp.max())


plt.figure(figsize=(10,6))
plt.plot(df["time"], df["regulator.50_uv"]/1e6, label="Little (A510)")
plt.plot(df["time"], df["regulator.51_uv"]/1e6, label="Big (A715)")
plt.plot(df["time"], df["regulator.49_uv"]/1e6, label="Prime (X3)")
plt.xlabel("Time (s)"); plt.ylabel("Voltage (V)")
plt.legend(); plt.grid(True); plt.show()
