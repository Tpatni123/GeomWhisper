# GeomWhisper example: explore the supplied lung.csv dataset
#
# This script can be run from the repository root or from this examples folder.
# It can also be uploaded as Initial Plot Code after lung.csv is uploaded in the app.

if (exists("user_data", inherits = FALSE)) {
  lung <- user_data
} else {
  if (file.exists("lung.csv")) {
    data_path <- "lung.csv"
  } else if (file.exists(file.path("examples", "lung.csv"))) {
    data_path <- file.path("examples", "lung.csv")
  } else {
    stop("Could not find lung.csv. Run this script from the repository root or examples folder.")
  }
  lung <- read.csv(data_path, check.names = FALSE)
}
names(lung)[1] <- "patient"

# In this dataset, status 1 means censored and status 2 means the event occurred.
lung$sex_label <- factor(
  lung$sex,
  levels = c(1, 2),
  labels = c("Male", "Female")
)

# A Kaplan-Meier curve is appropriate here because time is follow-up time and
# status indicates whether the event was observed or censored.
analysis_data <- lung[complete.cases(lung[, c("time", "status", "sex_label")]), ]
analysis_data$event <- analysis_data$status == 2
survival_fit <- survival::survfit(
  survival::Surv(time, event) ~ sex_label,
  data = analysis_data
)

# ggsurvplot handles confidence intervals and censor marks. Its plot component
# is assigned to p because GeomWhisper renders ggplot objects from that name.
p <- survminer::ggsurvplot(
  survival_fit,
  data = analysis_data,
  conf.int = TRUE,
  censor = TRUE,
  pval = TRUE,
  risk.table = FALSE,
  palette = c("#2C7FB8", "#D95F02"),
  title = "Estimated survival by sex",
  subtitle = paste0("Lung dataset; complete cases (n = ", nrow(analysis_data), ")"),
  xlab = "Follow-up time (days)",
  ylab = "Estimated survival probability",
  legend.title = "Sex"
)$plot

# Try prompts such as:
# - "Add confidence bands to the survival curves."
# - "Use a black-and-white theme suitable for print."
# - "Add a risk table below the plot."
