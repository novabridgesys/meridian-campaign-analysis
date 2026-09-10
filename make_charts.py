#!/usr/bin/env python3
"""
make_charts.py

Renders the analysis figures as PNGs for embedding in the case study.

Charts are generated from the SQL views rather than from a separate pandas
pipeline, so the figures cannot drift from the numbers in the written analysis.
Run after run_analysis.py.
"""

from pathlib import Path

import duckdb
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

ROOT = Path(__file__).parent
ASSETS = ROOT / "assets"
ASSETS.mkdir(exist_ok=True)

NAVY = "#1F3A5F"
BLUE = "#2E75B6"
RED = "#C0392B"
GREEN = "#1E8449"
GREY = "#8A9BA8"
LIGHT = "#F2F5F9"

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 10,
    "axes.titlesize": 13,
    "axes.titleweight": "bold",
    "axes.titlecolor": NAVY,
    "axes.labelcolor": "#333333",
    "axes.edgecolor": "#CCCCCC",
    "axes.grid": True,
    "grid.color": "#E8EDF2",
    "grid.linewidth": 0.8,
    "xtick.color": "#555555",
    "ytick.color": "#555555",
    "figure.facecolor": "white",
    "savefig.facecolor": "white",
    "savefig.bbox": "tight",
    "savefig.dpi": 150,
})


def connect():
    con = duckdb.connect()
    for f in ["sql/01_staging.sql", "sql/02_performance_analysis.sql",
              "sql/04_advanced_analysis.sql"]:
        con.execute((ROOT / f).read_text())
    return con


def chart_efficiency_index(con):
    df = con.execute("""
        SELECT channel, pct_of_total_conversions / pct_of_total_spend AS eff,
               total_cost, roi_pct
        FROM performance_by_channel ORDER BY eff
    """).df()

    fig, ax = plt.subplots(figsize=(9, 4.5))
    colors = [GREEN if v >= 1 else RED for v in df.eff]
    bars = ax.barh(df.channel, df.eff, color=colors, height=0.62)
    ax.axvline(1.0, color=NAVY, linestyle="--", linewidth=1.4, zorder=3)
    ax.text(1.02, -0.62, "Break-even (1.0)", color=NAVY, fontsize=9, style="italic")

    for bar, eff, cost in zip(bars, df.eff, df.total_cost):
        ax.text(eff + 0.04, bar.get_y() + bar.get_height() / 2,
                f"{eff:.2f}x   (${cost:,.0f} spend)",
                va="center", fontsize=9, color="#333333")

    ax.set_xlim(0, 2.6)
    ax.set_xlabel("Efficiency index: share of conversions ÷ share of spend")
    ax.set_title("Channel efficiency: Affiliate returns 2x its budget share, Display less than half")
    ax.grid(axis="y", visible=False)
    fig.savefig(ASSETS / "01_channel_efficiency.png")
    plt.close(fig)


def chart_confidence_forest(con):
    df = con.execute("""
        SELECT advertiser, sample_size, conversions, conversion_rate_pct,
               ci_lower_pct, ci_upper_pct, evidence_strength
        FROM advertiser_confidence ORDER BY conversion_rate_pct
    """).df()

    strength_color = {
        "Actionable": GREEN,
        "Directional": BLUE,
        "Insufficient sample": RED,
    }

    fig, ax = plt.subplots(figsize=(9.5, 5.2))
    y = range(len(df))
    for i, r in enumerate(df.itertuples()):
        c = strength_color[r.evidence_strength]
        ax.plot([r.ci_lower_pct, r.ci_upper_pct], [i, i], color=c, linewidth=2.6,
                solid_capstyle="round", zorder=2)
        ax.plot(r.conversion_rate_pct, i, "o", color=c, markersize=7,
                markeredgecolor="white", markeredgewidth=1.2, zorder=3)
        ax.text(r.ci_upper_pct + 0.9, i, f"n={r.sample_size}, k={int(r.conversions)}",
                va="center", fontsize=8.5, color="#666666")

    portfolio = con.execute(
        "SELECT 100.0*SUM(is_converted)/COUNT(*) FROM fct_leads").fetchone()[0]
    ax.axvline(portfolio, color=GREY, linestyle=":", linewidth=1.4, zorder=1)
    ax.text(portfolio + 0.4, -0.45, f"Portfolio {portfolio:.1f}%",
            color="#666666", fontsize=8.5, style="italic")

    ax.set_yticks(list(y))
    ax.set_yticklabels(df.advertiser)
    ax.set_xlim(0, 40)
    ax.set_xlabel("Conversion rate with 95% Wilson confidence interval")
    ax.set_title("Most advertiser differences are not statistically resolvable")
    ax.grid(axis="y", visible=False)

    handles = [plt.Line2D([], [], color=c, linewidth=2.6, marker="o",
                          markersize=6, markeredgecolor="white", label=k)
               for k, c in strength_color.items()]
    ax.legend(handles=handles, loc="lower right", frameon=True, fontsize=8.5,
              title="Evidence strength", title_fontsize=8.5)
    fig.savefig(ASSETS / "02_confidence_intervals.png")
    plt.close(fig)


def chart_loss_pareto(con):
    df = con.execute("""
        SELECT vertical, -net_contribution AS loss
        FROM performance_by_vertical
        WHERE net_contribution < 0
        ORDER BY loss DESC
    """).df()
    df["cum_pct"] = df.loss.cumsum() / df.loss.sum() * 100

    fig, ax = plt.subplots(figsize=(9, 4.6))
    bars = ax.bar(df.vertical, df.loss, color=NAVY, width=0.6)
    for bar, v in zip(bars, df.loss):
        ax.text(bar.get_x() + bar.get_width() / 2, v + 40, f"${v:,.0f}",
                ha="center", fontsize=9, color=NAVY, fontweight="bold")
    ax.set_ylabel("Net loss ($)")
    ax.set_ylim(0, df.loss.max() * 1.25)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"${x:,.0f}"))

    ax2 = ax.twinx()
    ax2.plot(df.vertical, df.cum_pct, color=RED, marker="o", linewidth=2, markersize=6)
    for x, v in zip(df.vertical, df.cum_pct):
        ax2.text(x, v + 4, f"{v:.0f}%", ha="center", fontsize=8.5, color=RED)
    ax2.set_ylabel("Cumulative % of total loss", color=RED)
    ax2.tick_params(axis="y", colors=RED)
    ax2.set_ylim(0, 118)
    ax2.grid(visible=False)

    ax.set_title("Loss concentration: two verticals account for 83% of the deficit")
    ax.grid(axis="x", visible=False)
    fig.savefig(ASSETS / "03_loss_pareto.png")
    plt.close(fig)


def chart_cost_quality(con):
    df = con.execute("SELECT * FROM cost_quality_frontier").df()

    action_color = {
        "Scale: high quality, low cost": GREEN,
        "Negotiate: high quality, high cost": BLUE,
        "Monitor: low quality, low cost": GREY,
        "Exit: low quality, high cost": RED,
    }
    med_cvr = df.conversion_rate_pct.median()
    med_cpl = df.avg_cost_per_lead.median()

    fig, ax = plt.subplots(figsize=(9.5, 6))
    ax.axvline(med_cpl, color="#BBBBBB", linestyle="--", linewidth=1.1, zorder=1)
    ax.axhline(med_cvr, color="#BBBBBB", linestyle="--", linewidth=1.1, zorder=1)

    for action, color in action_color.items():
        sub = df[df.recommended_action == action]
        if sub.empty:
            continue
        ax.scatter(sub.avg_cost_per_lead, sub.conversion_rate_pct,
                   s=sub.total_cost / 3.2, color=color, alpha=0.72,
                   edgecolors="white", linewidth=1.4, zorder=3,
                   label=action.split(":")[0])

    for r in df.itertuples():
        ax.annotate(r.campaign_id, (r.avg_cost_per_lead, r.conversion_rate_pct),
                    textcoords="offset points", xytext=(0, -16),
                    ha="center", fontsize=7.5, color="#444444")

    ax.text(med_cpl + 0.6, 29, "Higher cost per lead →", fontsize=8.5,
            color="#888888", style="italic")
    ax.set_xlabel("Average cost per lead ($)")
    ax.set_ylabel("Conversion rate (%)")
    ax.set_title("Cost / quality frontier by campaign (bubble size = total spend)")
    ax.legend(loc="upper left", frameon=True, fontsize=8.5, title="Recommended action",
              title_fontsize=8.5)
    ax.set_ylim(0, 32)
    fig.savefig(ASSETS / "04_cost_quality_frontier.png")
    plt.close(fig)


def chart_sensitivity(con):
    df = con.execute("SELECT * FROM sensitivity_grid").df()
    pivot = df.pivot(index="policy", columns="redeployment_efficiency",
                     values="projected_net")
    order = ["25% of benchmark", "50% of benchmark",
             "75% of benchmark", "100% of benchmark"]
    pivot = pivot[order].sort_index(ascending=False)

    fig, ax = plt.subplots(figsize=(9, 3.6))
    vmax = abs(pivot.values).max()
    im = ax.imshow(pivot.values, cmap="RdYlGn", vmin=-vmax, vmax=vmax, aspect="auto")

    for i in range(pivot.shape[0]):
        for j in range(pivot.shape[1]):
            v = pivot.values[i, j]
            label = f"-${abs(v):,.0f}" if v < 0 else f"${v:,.0f}"
            ax.text(j, i, label, ha="center", va="center",
                    fontsize=10, fontweight="bold",
                    color="#222222")

    ax.set_xticks(range(len(order)))
    ax.set_xticklabels([o.replace(" of benchmark", "") for o in order])
    ax.set_yticks(range(pivot.shape[0]))
    ax.set_yticklabels(pivot.index, fontsize=9)
    ax.set_xlabel("Redeployment efficiency retained (% of Affiliate benchmark)")
    ax.set_title("Sensitivity: projected monthly net contribution")
    ax.grid(visible=False)
    cb = fig.colorbar(im, ax=ax, shrink=0.85)
    cb.set_label("Projected net ($)", fontsize=9)
    fig.savefig(ASSETS / "05_sensitivity_grid.png")
    plt.close(fig)


def chart_weekly(con):
    df = con.execute("SELECT * FROM weekly_trend").df()
    df["label"] = [f"W{i+1}" for i in range(len(df))]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(9, 5.4), sharex=True,
                                   gridspec_kw={"height_ratios": [1, 1]})
    ax1.bar(df.label, df.leads, color=BLUE, width=0.55)
    for x, v in zip(df.label, df.leads):
        ax1.text(x, v + 3, str(v), ha="center", fontsize=9, color=NAVY)
    ax1.set_ylabel("Leads")
    ax1.set_title("Weekly volume and margin")
    ax1.set_ylim(0, df.leads.max() * 1.22)
    ax1.grid(axis="x", visible=False)

    ax2.bar(df.label, df.net_contribution, color=RED, width=0.55)
    for x, v in zip(df.label, df.net_contribution):
        ax2.text(x, v - 90, f"-${abs(v):,.0f}" if v < 0 else f"${v:,.0f}", ha="center", fontsize=8.5, color=RED)
    ax2.axhline(0, color=NAVY, linewidth=1.1)
    ax2.set_ylabel("Net contribution ($)")
    ax2.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"${x:,.0f}"))
    ax2.set_ylim(df.net_contribution.min() * 1.4, 200)
    ax2.grid(axis="x", visible=False)
    fig.savefig(ASSETS / "06_weekly_trend.png")
    plt.close(fig)


def main():
    con = connect()
    chart_efficiency_index(con)
    chart_confidence_forest(con)
    chart_loss_pareto(con)
    chart_cost_quality(con)
    chart_sensitivity(con)
    chart_weekly(con)
    for f in sorted(ASSETS.glob("*.png")):
        print(f"  {f.name}")


if __name__ == "__main__":
    main()
