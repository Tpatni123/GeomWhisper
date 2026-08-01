library(ggplot2)
library(ggsurvfit)
library(survival)
library(dplyr)

# user_data is the uploaded lung.csv (pre-loaded by the app)
# Recode sex as a labelled factor
df <- user_data
df$sex <- factor(df$sex, levels = c(1, 2), labels = c("Male", "Female"))
df$status_surv <- ifelse(df$status == 2, 1, 0)  # 2=dead → 1 for Surv()

# ── Plot 1: Overall Kaplan-Meier curve ────────────────────────────────────────
p <- survfit2(Surv(time, status_surv) ~ 1, data = df) |>
  ggsurvfit(linewidth = 1, color = "steelblue") +
  add_confidence_interval(fill = "steelblue", alpha = 0.15) +
  add_risktable(risktable_stats = "n.risk") +
  add_censor_mark(shape = 3, size = 2.5) +
  scale_x_continuous(breaks = seq(0, 1100, 200)) +
  labs(
    title   = "Overall Survival — Lung Cancer Cohort",
    x       = "Time (days)",
    y       = "Survival Probability"
  ) +
  theme_minimal(base_size = 13) +
  theme(plot.title = element_text(face = "bold"))

# ── Plot 2: KM stratified by sex ──────────────────────────────────────────────
by_sex <- survfit2(Surv(time, status_surv) ~ sex, data = df) |>
  ggsurvfit(linewidth = 1) +
  add_confidence_interval(alpha = 0.12) +
  add_risktable(risktable_stats = "n.risk") +
  add_censor_mark(shape = 3, size = 2.5) +
  add_pvalue(location = "annotation", prepend_p = TRUE) +
  scale_color_manual(values = c("Male" = "#2196F3", "Female" = "#E91E63")) +
  scale_fill_manual(values  = c("Male" = "#2196F3", "Female" = "#E91E63")) +
  scale_x_continuous(breaks = seq(0, 1100, 200)) +
  labs(
    title    = "Survival by Sex",
    x        = "Time (days)",
    y        = "Survival Probability",
    color    = "Sex",
    fill     = "Sex"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title   = element_text(face = "bold"),
    legend.position = "top"
  )

# ── Plot 3: KM stratified by ECOG performance score (0–2) ─────────────────────
df_ecog <- df |> filter(!is.na(ph.ecog), ph.ecog %in% 0:2)
df_ecog$ecog_label <- factor(
  df_ecog$ph.ecog,
  levels = 0:2,
  labels = c("ECOG 0 (Asymptomatic)", "ECOG 1 (Ambulatory)", "ECOG 2 (Limited)")
)

ecog_plot <- survfit2(Surv(time, status_surv) ~ ecog_label, data = df_ecog) |>
  ggsurvfit(linewidth = 1) +
  add_confidence_interval(alpha = 0.12) +
  add_censor_mark(shape = 3, size = 2.5) +
  add_pvalue(location = "annotation", prepend_p = TRUE) +
  scale_color_manual(values = c(
    "ECOG 0 (Asymptomatic)" = "#4CAF50",
    "ECOG 1 (Ambulatory)"   = "#FF9800",
    "ECOG 2 (Limited)"      = "#F44336"
  )) +
  scale_fill_manual(values = c(
    "ECOG 0 (Asymptomatic)" = "#4CAF50",
    "ECOG 1 (Ambulatory)"   = "#FF9800",
    "ECOG 2 (Limited)"      = "#F44336"
  )) +
  scale_x_continuous(breaks = seq(0, 1100, 200)) +
  labs(
    title = "Survival by ECOG Performance Score",
    x     = "Time (days)",
    y     = "Survival Probability",
    color = NULL,
    fill  = NULL
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title      = element_text(face = "bold"),
    legend.position = "top"
  )
