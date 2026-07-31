library(readxl)
library(dplyr)
library(ggplot2)

D  <- "/Users/karentao/MIT Dropbox/Karen Tao/AI_and_Development_MIT_FutureTech/Karen/05 Task Length Exercise/"
FK <- "/Users/karentao/Downloads/for_karen.xlsx"

#u.s. filtered
onet_exp <- read.csv(paste0(D, "onet_ai_exposure.csv"),
                     stringsAsFactors = FALSE)[, c("task", "llme")]
keep <- unique(onet_exp$task[onet_exp$llme != "LLME0"])

us <- read_excel(FK) %>%
  mutate(gemini_hours = as.numeric(gemini_hours)) %>%
  filter(task %in% keep, !is.na(gemini_hours), gemini_hours > 0) %>%
  transmute(ln_hours = log(gemini_hours), source = "U.S. (O*NET)")

# --- India: NCO, already LLME1+ ---------------------------------------------
india <- read.csv(paste0(D, "tasklength_nco_llme1plus.csv"),
                  stringsAsFactors = FALSE) %>%
  filter(!is.na(duration), duration > 0) %>%          # duration_units is all "hours"
  transmute(ln_hours = log(duration), source = "India (NCO)")

df <- bind_rows(us, india)

meds <- df %>%
  group_by(source) %>%
  summarise(m = median(ln_hours), n = n(), .groups = "drop") %>%
  mutate(lab = sprintf("%s, n=%d, median %.2fh", source, n, exp(m)))

df <- left_join(df, meds[, c("source", "lab")], by = "source")

pal <- c("U.S. (O*NET)" = "#4C78A8", "India (NCO)" = "#E45756")
names(pal) <- meds$lab[match(names(pal), meds$source)]

ggplot(df, aes(ln_hours, fill = lab, colour = lab)) +
  geom_density(alpha = 0.25, linewidth = 0.8) +
  geom_vline(data = left_join(meds, meds[, c("source", "lab")], by = c("source", "lab")),
             aes(xintercept = m, colour = lab), linetype = "dashed", linewidth = 0.4) +
  scale_fill_manual(values = pal) +
  scale_colour_manual(values = pal) +
  labs(x = "ln(hours)", y = "density",
       title = "Gemini task lengths, LLME1+ only",
       fill = NULL, colour = NULL) +
  theme_minimal() +
  theme(legend.position = "top")

ggsave("/Users/karentao/Downloads/gemini_hours_density_llme1plus.png",
       width = 9, height = 5, dpi = 150)
