import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch, Circle, Polygon
import numpy as np

# Set style for academic papers
plt.rcParams['font.family'] = 'serif'
plt.rcParams['font.serif'] = ['Times New Roman', 'DejaVu Serif']
plt.rcParams['font.size'] = 9
plt.rcParams['axes.labelsize'] = 10

# Create figure
fig, ax = plt.subplots(figsize=(14, 11))
ax.set_xlim(0, 14)
ax.set_ylim(0, 12)
ax.axis('off')

# Define colors
color_source = '#34495e'  # Dark gray (Power Profiler - source)
color_power = '#3498db'  # Blue (Power measurement)
color_voltage = '#e67e22'  # Orange (Voltage)
color_ceff = '#27ae60'  # Green (C_eff)
color_validation = '#8e44ad'  # Purple (Validation)
color_border = '#2c3e50'
color_light_bg = '#ecf0f1'
color_arrow = '#34495e'

# Title
ax.text(7, 11.5, 'Methodology Pipeline for ARM-Based Mobile Devices',
        ha='center', va='top', fontsize=14, fontweight='bold')

# ============================================================================
# POWER PROFILER (SOURCE/FOUNDATION)
# ============================================================================
profiler_y = 9.5
profiler_box = FancyBboxPatch((4, profiler_y - 0.8), 6, 1.8,
                              boxstyle="round,pad=0.15",
                              edgecolor=color_source, facecolor='#d5dbdb',
                              linewidth=3)
ax.add_patch(profiler_box)

# Title with icon
ax.text(7, profiler_y + 0.7, '⚙ Power Profiler Platform ⚙', ha='center', va='top',
        fontsize=12, fontweight='bold', color=color_source)
ax.text(7, profiler_y + 0.35, '(Foundation Tool)', ha='center', va='top',
        fontsize=9, style='italic', color=color_source)

# Functionalities in two columns
left_col_x = 5
right_col_x = 8.2

ax.text(left_col_x, profiler_y + 0.05, 'Core Functionality:', ha='left', va='top',
        fontsize=8, fontweight='bold')
ax.text(left_col_x, profiler_y - 0.15, '• Battery voltage (V_batt)', ha='left', va='top', fontsize=7.5)
ax.text(left_col_x, profiler_y - 0.35, '• Battery current (I_batt)', ha='left', va='top', fontsize=7.5)
ax.text(left_col_x, profiler_y - 0.55, '• P_batt = V_batt × I_batt', ha='left', va='top', fontsize=7.5)

ax.text(right_col_x, profiler_y + 0.05, 'Extended Capability:', ha='left', va='top',
        fontsize=8, fontweight='bold')
ax.text(right_col_x, profiler_y - 0.15, '• Regulator rail voltages', ha='left', va='top', fontsize=7.5)
ax.text(right_col_x, profiler_y - 0.35, '• Backend server storage', ha='left', va='top', fontsize=7.5)
ax.text(right_col_x, profiler_y - 0.55, '• Real-time KPI monitoring', ha='left', va='top', fontsize=7.5)

# ============================================================================
# BRANCH 1: POWER MEASUREMENT PATH (Left)
# ============================================================================

# Arrow down from profiler to power measurement
arrow_to_power = FancyArrowPatch((5.5, profiler_y - 0.8), (3.5, profiler_y - 1.8),
                                 arrowstyle='->', mutation_scale=25, linewidth=2.5,
                                 color=color_power)
ax.add_patch(arrow_to_power)
ax.text(4.2, profiler_y - 1.3, 'P_batt', ha='center', va='center',
        fontsize=8, style='italic', color=color_power,
        bbox=dict(boxstyle='round,pad=0.3', facecolor='white', edgecolor=color_power))

# Phase 1: CPU Power Measurement
phase1_y = 6.5
phase1_box = FancyBboxPatch((0.5, phase1_y - 1.5), 6, 2.5,
                            boxstyle="round,pad=0.15",
                            edgecolor=color_power, facecolor='#ebf5fb',
                            linewidth=2.5)
ax.add_patch(phase1_box)

# Phase number circle
circle1 = Circle((1.3, phase1_y + 0.7), 0.3, color=color_power, zorder=10)
ax.add_patch(circle1)
ax.text(1.3, phase1_y + 0.7, '1', ha='center', va='center',
        fontsize=12, fontweight='bold', color='white', zorder=11)

# Content
ax.text(3.5, phase1_y + 0.7, 'CPU Power Measurement', ha='center', va='top',
        fontsize=11, fontweight='bold', color=color_power)
ax.text(3.5, phase1_y + 0.35, 'Control conditions to make P_batt ≈ P_CPU', ha='center', va='top',
        fontsize=8, style='italic')

# Configuration
ax.text(1.2, phase1_y + 0.05, 'Device Configuration:', ha='left', va='top',
        fontsize=8, fontweight='bold')
ax.text(1.4, phase1_y - 0.2, '• Screen OFF, Radios OFF', ha='left', va='top', fontsize=7.5)
ax.text(1.4, phase1_y - 0.4, '• Airplane mode, No charging', ha='left', va='top', fontsize=7.5)
ax.text(1.4, phase1_y - 0.6, '• Minimize non-CPU components', ha='left', va='top', fontsize=7.5)

# Isolation mechanisms
ax.text(4.2, phase1_y + 0.05, 'Core Isolation:', ha='left', va='top',
        fontsize=8, fontweight='bold')
ax.text(4.4, phase1_y - 0.2, '• Shielding (OS → SYSTEM_CORE)', ha='left', va='top', fontsize=7.5)
ax.text(4.4, phase1_y - 0.4, '• Pinning (stress-ng → target cores)', ha='left', va='top', fontsize=7.5)
ax.text(4.4, phase1_y - 0.6, '• Off-lining (disable non-target cores)', ha='left', va='top', fontsize=7.5)

# Measurement sequence
ax.text(3.5, phase1_y - 0.85, 'Measurement Sequence:', ha='center', va='top',
        fontsize=8, fontweight='bold', style='italic')

meas_y = phase1_y - 1.3
meas_boxes = [
    ('idle_min', 0.9), ('idle_max', 1.9), ('load_min', 2.9),
    ('cooldown', 3.9), ('load_max', 4.9)
]

for label, x_pos in meas_boxes:
    box = FancyBboxPatch((x_pos, meas_y), 0.85, 0.3,
                         boxstyle="round,pad=0.03",
                         edgecolor=color_power, facecolor='white',
                         linewidth=1.5)
    ax.add_patch(box)
    ax.text(x_pos + 0.425, meas_y + 0.15, label, ha='center', va='center',
            fontsize=6.5, fontweight='bold')

    if x_pos < 4.9:
        ax.arrow(x_pos + 0.85, meas_y + 0.15, 0.1, 0,
                 head_width=0.08, head_length=0.04, fc=color_arrow, ec=color_arrow)

# Output
output1 = FancyBboxPatch((1, phase1_y - 1.8), 4.5, 0.25,
                         boxstyle="round,pad=0.05",
                         edgecolor=color_power, facecolor='white',
                         linewidth=1.5, linestyle='--')
ax.add_patch(output1)
ax.text(3.25, phase1_y - 1.675, 'P_dyn = P_load - P_idle  at (f_min, f_max)',
        ha='center', va='center', fontsize=7, style='italic', fontweight='bold')

# ============================================================================
# BRANCH 2: VOLTAGE EXTRACTION PATH (Right)
# ============================================================================

# Arrow down from profiler to rail mapping
arrow_to_voltage = FancyArrowPatch((8.5, profiler_y - 0.8), (10.5, profiler_y - 1.8),
                                   arrowstyle='->', mutation_scale=25, linewidth=2.5,
                                   color=color_voltage)
ax.add_patch(arrow_to_voltage)
ax.text(9.8, profiler_y - 1.3, 'V_reg', ha='center', va='center',
        fontsize=8, style='italic', color=color_voltage,
        bbox=dict(boxstyle='round,pad=0.3', facecolor='white', edgecolor=color_voltage))

# Phase 2: Rail-to-Cluster Mapping
phase2_y = 7.8
phase2_box = FancyBboxPatch((7.5, phase2_y - 1), 6, 1.8,
                            boxstyle="round,pad=0.15",
                            edgecolor=color_voltage, facecolor='#fef5e7',
                            linewidth=2.5)
ax.add_patch(phase2_box)

# Phase number circle
circle2 = Circle((8.3, phase2_y + 0.5), 0.3, color=color_voltage, zorder=10)
ax.add_patch(circle2)
ax.text(8.3, phase2_y + 0.5, '2', ha='center', va='center',
        fontsize=12, fontweight='bold', color='white', zorder=11)

# Content
ax.text(10.5, phase2_y + 0.5, 'Rail-to-Cluster Mapping', ha='center', va='top',
        fontsize=11, fontweight='bold', color=color_voltage)
ax.text(10.5, phase2_y + 0.15, 'Reverse-engineer voltage rail assignment', ha='center', va='top',
        fontsize=8, style='italic')

# Steps
ax.text(8.2, phase2_y - 0.15, '• Baseline: All clusters @ f_min (idle)', ha='left', va='top', fontsize=8)
ax.text(8.2, phase2_y - 0.4, '• Activate LITTLE @ f_max → identify V_LITTLE', ha='left', va='top', fontsize=8)
ax.text(8.2, phase2_y - 0.65, '• Activate Big @ f_max → identify V_Big', ha='left', va='top', fontsize=8)
ax.text(8.2, phase2_y - 0.9, '• Activate Prime @ f_max → identify V_Prime', ha='left', va='top', fontsize=8)

# Output
output2 = FancyBboxPatch((7.8, phase2_y - 1.3), 5.4, 0.25,
                         boxstyle="round,pad=0.05",
                         edgecolor=color_voltage, facecolor='white',
                         linewidth=1.5, linestyle='--')
ax.add_patch(output2)
ax.text(10.5, phase2_y - 1.175, 'Cluster → Rail mapping',
        ha='center', va='center', fontsize=7, style='italic', fontweight='bold')

# Phase 3: Voltage Extraction
phase3_y = 5.5
phase3_box = FancyBboxPatch((7.5, phase3_y - 0.8), 6, 1.3,
                            boxstyle="round,pad=0.15",
                            edgecolor=color_voltage, facecolor='#fef5e7',
                            linewidth=2.5)
ax.add_patch(phase3_box)

# Phase number circle
circle3 = Circle((8.3, phase3_y + 0.3), 0.3, color=color_voltage, zorder=10)
ax.add_patch(circle3)
ax.text(8.3, phase3_y + 0.3, '3', ha='center', va='center',
        fontsize=12, fontweight='bold', color='white', zorder=11)

# Content
ax.text(10.5, phase3_y + 0.3, 'Voltage Extraction', ha='center', va='top',
        fontsize=11, fontweight='bold', color=color_voltage)
ax.text(8.2, phase3_y - 0.05, '• Extract V_min at f_min for each cluster', ha='left', va='top', fontsize=8)
ax.text(8.2, phase3_y - 0.3, '• Extract V_max at f_max for each cluster', ha='left', va='top', fontsize=8)
ax.text(8.2, phase3_y - 0.55, '• Determine operating voltage ranges', ha='left', va='top', fontsize=8)

# Output
output3 = FancyBboxPatch((7.8, phase3_y - 1.05), 5.4, 0.25,
                         boxstyle="round,pad=0.05",
                         edgecolor=color_voltage, facecolor='white',
                         linewidth=1.5, linestyle='--')
ax.add_patch(output3)
ax.text(10.5, phase3_y - 0.925, '(V_min, V_max) per_cluster',
        ha='center', va='center', fontsize=7, style='italic', fontweight='bold')

# Arrow from Phase 2 to Phase 3
arrow_2_3 = FancyArrowPatch((10.5, phase2_y - 1.4), (10.5, phase3_y + 0.5),
                            arrowstyle='->', mutation_scale=25, linewidth=2,
                            color=color_voltage)
ax.add_patch(arrow_2_3)

# ============================================================================
# CONVERGENCE TO C_EFF EXTRACTION
# ============================================================================

# Arrows converging to C_eff
arrow_power_to_ceff = FancyArrowPatch((3.5, phase1_y - 2), (5, 3.3),
                                      arrowstyle='->', mutation_scale=25, linewidth=2.5,
                                      color=color_power)
ax.add_patch(arrow_power_to_ceff)
ax.text(3.8, 3, 'P_dyn', ha='center', va='center', fontsize=8, style='italic',
        bbox=dict(boxstyle='round,pad=0.3', facecolor='white', edgecolor=color_power))

arrow_voltage_to_ceff = FancyArrowPatch((10.5, phase3_y - 1.2), (9, 3.3),
                                        arrowstyle='->', mutation_scale=25, linewidth=2.5,
                                        color=color_voltage)
ax.add_patch(arrow_voltage_to_ceff)
ax.text(10.2, 3, 'V, f', ha='center', va='center', fontsize=8, style='italic',
        bbox=dict(boxstyle='round,pad=0.3', facecolor='white', edgecolor=color_voltage))

# Phase 4: C_eff Extraction
phase4_y = 2.8
phase4_box = FancyBboxPatch((3.5, phase4_y - 2.2), 7, 2.5,
                            boxstyle="round,pad=0.15",
                            edgecolor=color_ceff, facecolor='#eafaf1',
                            linewidth=2.5)
ax.add_patch(phase4_box)

# Phase number circle
circle4 = Circle((4.3, phase4_y), 0.3, color=color_ceff, zorder=10)
ax.add_patch(circle4)
ax.text(4.3, phase4_y, '4', ha='center', va='center',
        fontsize=12, fontweight='bold', color='white', zorder=11)

# Content
ax.text(7, phase4_y, 'Effective Capacitance Extraction', ha='center', va='top',
        fontsize=11, fontweight='bold', color=color_ceff)

# Core activation strategies
ax.text(7, phase4_y - 0.35, 'Core Activation Strategies:', ha='center', va='top',
        fontsize=9, fontweight='bold', style='italic')

strategy_y = phase4_y - 0.7
# Per-Cluster
cluster_box = FancyBboxPatch((4, strategy_y - 0.3), 1.8, 0.55,
                             boxstyle="round,pad=0.05",
                             edgecolor=color_ceff, facecolor='white',
                             linewidth=1.5)
ax.add_patch(cluster_box)
ax.text(4.9, strategy_y - 0.05, 'Per-Cluster', ha='center', va='center',
        fontsize=8, fontweight='bold')
ax.text(4.9, strategy_y - 0.25, 'All cores together', ha='center', va='center',
        fontsize=7)

# Incremental
incr_box = FancyBboxPatch((6.1, strategy_y - 0.3), 1.8, 0.55,
                          boxstyle="round,pad=0.05",
                          edgecolor=color_ceff, facecolor='white',
                          linewidth=1.5)
ax.add_patch(incr_box)
ax.text(7, strategy_y - 0.05, 'Incremental', ha='center', va='center',
        fontsize=8, fontweight='bold')
ax.text(7, strategy_y - 0.25, '+1 core per step', ha='center', va='center',
        fontsize=7)

# Single
single_box = FancyBboxPatch((8.2, strategy_y - 0.3), 1.8, 0.55,
                            boxstyle="round,pad=0.05",
                            edgecolor=color_ceff, facecolor='white',
                            linewidth=1.5)
ax.add_patch(single_box)
ax.text(9.1, strategy_y - 0.05, 'Single', ha='center', va='center',
        fontsize=8, fontweight='bold')
ax.text(9.1, strategy_y - 0.25, '1 core only', ha='center', va='center',
        fontsize=7)

# Models
ax.text(7, phase4_y - 1.35, 'Analytical Models:', ha='center', va='top',
        fontsize=9, fontweight='bold', style='italic')

model_y = phase4_y - 1.65

# Exact Model
exact_box = FancyBboxPatch((4.2, model_y - 0.3), 2.3, 0.5,
                           boxstyle="round,pad=0.05",
                           edgecolor='#16a085', facecolor='#d1f2eb',
                           linewidth=2)
ax.add_patch(exact_box)
ax.text(5.35, model_y - 0.05, 'Exact (Voltage-Aware)', ha='center', va='center',
        fontsize=8, fontweight='bold', color='#16a085')
ax.text(5.35, model_y - 0.25, 'C_eff = P_dyn / (f · V²)', ha='center', va='center',
        fontsize=8)

# Approximate Model
approx_box = FancyBboxPatch((7.5, model_y - 0.3), 2.3, 0.5,
                            boxstyle="round,pad=0.05",
                            edgecolor='#c0392b', facecolor='#fadbd8',
                            linewidth=2)
ax.add_patch(approx_box)
ax.text(8.65, model_y - 0.05, 'Approx (Frequency-Only)', ha='center', va='center',
        fontsize=8, fontweight='bold', color='#c0392b')
ax.text(8.65, model_y - 0.25, 'C_eff = P_dyn / f³', ha='center', va='center',
        fontsize=8)

# Output
output4 = FancyBboxPatch((3.8, phase4_y - 2.45), 6.4, 0.25,
                         boxstyle="round,pad=0.05",
                         edgecolor=color_ceff, facecolor='white',
                         linewidth=1.5, linestyle='--')
ax.add_patch(output4)
ax.text(7, phase4_y - 2.325, 'C_eff per_cluster (exact & approximate)',
        ha='center', va='center', fontsize=7, style='italic', fontweight='bold')

# ============================================================================
# VALIDATION
# ============================================================================

# Arrow to validation
arrow_to_val = FancyArrowPatch((7, phase4_y - 2.6), (7, phase4_y - 3.3),
                               arrowstyle='->', mutation_scale=25, linewidth=2,
                               color=color_validation)
ax.add_patch(arrow_to_val)

validation_y = -1
validation_box = FancyBboxPatch((2, validation_y), 10, 1.2,
                                boxstyle="round,pad=0.15",
                                edgecolor=color_validation, facecolor='#f4ecf7',
                                linewidth=2.5)
ax.add_patch(validation_box)

ax.text(7, validation_y + 0.85, '✓ Validation & Model Comparison', ha='center', va='top',
        fontsize=11, fontweight='bold', color=color_validation)

ax.text(3, validation_y + 0.5, '• Compare exact vs. approximate C_eff values',
        ha='left', va='top', fontsize=8)
ax.text(3, validation_y + 0.25, '• Compute prediction error: |P_est - P_meas| / P_meas',
        ha='left', va='top', fontsize=8)
ax.text(3, validation_y, '• Evaluate accuracy across all clusters and frequencies',
        ha='left', va='top', fontsize=8)

plt.tight_layout()
plt.savefig('mobile_methodology_pipeline.pdf', dpi=300, bbox_inches='tight')
plt.savefig('mobile_methodology_pipeline.png', dpi=300, bbox_inches='tight')
plt.show()

print("✓ Pipeline figure saved successfully!")
print("\nRevised Pipeline Structure:")
print("━" * 60)
print("SOURCE: Power Profiler Platform")
print("  ├─→ Measures P_batt = V_batt × I_batt")
print("  └─→ Tracks regulator rail voltages (V_reg)")
print()
print("BRANCH 1 (Left): Power Measurement")
print("  Phase 1: CPU Power Measurement")
print("    └─→ Control conditions: P_batt ≈ P_CPU")
print("    └─→ Output: P_dyn at (f_min, f_max)")
print()
print("BRANCH 2 (Right): Voltage Extraction")
print("  Phase 2: Rail-to-Cluster Mapping")
print("    └─→ Reverse-engineer rail assignments")
print("  Phase 3: Voltage Extraction")
print("    └─→ Output: (V_min, V_max) per_cluster")
print()
print("CONVERGENCE:")
print("  Phase 4: C_eff Extraction")
print("    ├─→ Input: P_dyn (from Phase 1)")
print("    ├─→ Input: V, f (from Phases 2-3)")
print("    └─→ Output: C_eff (exact & approx models)")
print()
print("VALIDATION:")
print("  └─→ Compare models and compute errors")
print("━" * 60)