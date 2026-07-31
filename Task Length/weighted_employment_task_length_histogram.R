# I use raw gemini estimates for both NCO and O*NET.
# Weighting: each occupation's employment is divided equally across its tasks
# and I also use the individual sample weights

#i consulted: https://medium.com/@yadaviitb2018/working-with-periodic-labour-force-survey-plfs-data-in-python-part-2-f0918c2b3538
# and also https://www.mospi.gov.in/sites/default/files/main_menu/plfs_cy_21/README.pdf to design this:

suppressMessages({
  library(haven); library(dplyr); library(tidyr); library(stringr)
  library(readr); library(readxl); library(ggplot2); library(scales)
})

ROOT    <- "/Users/karentao/MIT Dropbox/Karen Tao/AI_and_Development_MIT_FutureTech/Karen/05 Task Length Exercise"
BASE    <- file.path(ROOT, "00 source")
DL      <- path.expand("~/Downloads")
OUT_DIR <- file.path(ROOT, "01 histogram employment weighted figures")
VARIANTS <- list(
  list(us = "acs",  scope = "all",    restrict = TRUE),
  list(us = "oews", scope = "formal", restrict = FALSE)
  #oews data is only for the formal sector
)

# histogram is better to spot issues with the method, like the sudden spikes due to certain occupations having a heavy weight distributed on few tasks
PLOT_TYPES <- c("density", "histogram")

# Prime age workforce restriction
# coded 1 = male in PLFS b4q5 and in ACS also coded 1 = male
AGE_MIN <- 25; AGE_MAX <- 54; SEX_CODE <- 1
AGE_FLOOR  <- 16

C_IND  <- "#69b3a2"   
C_ONET <- "#404080"   
INK2   <- "#52514e"; GRID <- "#e3e2dd"

LAB_IND  <- "India raw Gemini, LLME1+"
LAB_ONET <- "O*NET raw Gemini, LLME1+"

# hour conversion
hr_breaks <- log(c(1/3600, 1/60, 10/60, 1, 4, 8, 24, 168, 720))
hr_labels <- c("1 sec", "1 min", "10 min", "1 hr", "4 hr", "8 hr", "1 day", "1 wk", "1 mo")

w_quantile <- function(x, w, probs) {
  o  <- order(x); x <- x[o]; w <- w[o]
  cw <- (cumsum(w) - 0.5 * w) / sum(w)
  approx(cw, x, xout = probs, rule = 2)$y
}
w_mean <- function(x, w) sum(x * w) / sum(w)
w_sd   <- function(x, w) sqrt(sum(w * (x - w_mean(x, w))^2) / sum(w))

# to extract PLFS data, need num and chr conversion
as_chr <- function(x) str_trim(as.character(haven::zap_labels(x)))
as_num <- function(x) suppressWarnings(as.numeric(as_chr(x)))

# llme1+
ind <- read_csv(file.path(BASE, "tasklength_nco_llme1plus.csv"),
                col_types = cols(soc_code = col_character(), .default = col_guess()))

# hard stop on 0 or negative or n/a for duration, as taking log can lead to issue
stopifnot(!any(is.na(ind$duration)), all(is.finite(ind$duration)),
          min(ind$duration) > 0, max(ind$duration) <= 672 + 1e-9)

# under 1 min rows
n_sub <- sum(ind$duration < 1 / 60 - 1e-9)
if (n_sub > 0)
  message(sprintf("India: %d row(s) average below the 1-min prompt floor (min %.3f min)",
                  n_sub, min(ind$duration) * 60))

ind <- ind %>% select(-any_of(c("log_dur", "est_log_dur")))

# gemini estimated a few tasks twice due a bug, so only keep the latest run.
ndup <- nrow(ind) - nrow(distinct(ind, soc_code, task))
if (ndup > 0) {
  n_pre <- nrow(ind)
  ind <- ind %>% group_by(soc_code, task) %>%
    filter(row_number() == n()) %>% ungroup()
  message(sprintf("India: dropped %s superseded task row(s), %s -> %s",
                  comma(n_pre - nrow(ind)), comma(n_pre), comma(nrow(ind))))
}
ind <- ind %>% mutate(log_dur = log(duration))        # recompute; never reuse

# rawonet.xlsx 
onet <- read_excel(file.path(BASE, "rawonet.xlsx"), sheet = 1,
                   col_types = c("text", "text", "text",
                                 "numeric", "numeric", "numeric", "numeric")) %>%
  mutate(across(c(soc_code, task), str_trim))
stopifnot(!any(is.na(onet$gemini_hours)),
          abs(min(onet$gemini_hours) - 1 / 60) < 1e-9,
          abs(max(onet$gemini_hours) - 672) < 1e-9)
onet <- onet %>% mutate(log_dur = log(gemini_hours))  # recompute

# restrict the O*NET universe to all_onet_task_lengths.csv
universe <- read_csv(file.path(BASE, "all_onet_task_lengths.csv"),
                     col_types = cols(.default = col_guess())) %>%
  transmute(soc_code = str_trim(`O*NET-SOC Code`), task = str_trim(Task)) %>%
  distinct()
n_all <- nrow(onet)
onet  <- onet %>% semi_join(universe, by = c("soc_code", "task"))
message(sprintf("O*NET universe: %s of %s rawonet rows kept (%s absent from all_onet_task_lengths.csv)",
                comma(nrow(onet)), comma(n_all), comma(n_all - nrow(onet))))
stopifnot(nrow(onet) == 18796, nrow(universe) == 18796)

# The India pool is already LLME1+, restrict O*NET the same way.
# Join on the PAIR (soc_code, task), never on task text alone
oe <- read_csv(file.path(BASE, "onet_ai_exposure.csv"),
               col_types = cols(.default = col_character())) %>%
  mutate(llme_n = as.integer(str_extract(llme, "\\d$"))) %>%
  filter(llme_n >= 1) %>%
  distinct(occupation_code, task)
stopifnot(nrow(distinct(onet, soc_code, task)) == nrow(onet))

# employment is divided over total tasks in an occupation, including llme0 tasks. 
onet_all_n <- onet %>%
  mutate(soc6 = str_remove(str_sub(soc_code, 1, 7), "-")) %>%
  count(soc6, name = "n_tasks_all")

n_before <- nrow(onet)
onet <- onet %>% semi_join(oe, by = c("soc_code" = "occupation_code", "task" = "task"))
message(sprintf("O*NET LLME1+: %s of %s tasks kept (%.1f%%)",
                comma(nrow(onet)), comma(n_before), 100 * nrow(onet) / n_before))
message(sprintf("India LLME1+ : %s tasks, %s NCO codes",
                comma(nrow(ind)), comma(n_distinct(ind$soc_code))))


# PLFS Jan-Dec 2022, NCO 3-digit
#      Final weight = MULT/(NO_QTR*100) if NSS = NSC
#                   = MULT/(NO_QTR*200) otherwise
#    IMF uses 11,12, 21, 31, 41,42, 51, 61, 62, 71 and 72 to code employment
plfs <- read_dta(file.path(DL, "PLFS_Data_2022-22_STATA/cperv1.dta"),
                 col_select = c(b5pt1q6_cperv1, b5pt1q3_cperv1, b4q5_cperv1, b4q6_perv1,
                                mult_cperv1, nss_cperv1, nsc_cperv1, no_qtr_cperv1))
#load ACS data from IPUMS, included perwt, age, sex, empstat, occsoc variables.
acs_raw <- if (any(sapply(VARIANTS, function(v) v$us == "acs")))
  read_dta(file.path(DL, "acs 2022.dta"),
           col_select = c(perwt, age, sex, empstat, empstatd, occsoc)) else NULL

run_variant <- function(US_SOURCE, IND_SCOPE, RESTRICT) {
  stopifnot(US_SOURCE %in% c("acs", "oews"), IND_SCOPE %in% c("all", "formal"))
  if (US_SOURCE == "oews" && RESTRICT)
    stop("OEWS has no age or sex fields; restrict must be FALSE when us='oews'")

  IND_STATUS   <- if (IND_SCOPE == "formal") "31" else
                    c("11","12", "21", "31", "41","42","51", "61", "62", "71", "72")
  RESTRICT_LAB <- if (RESTRICT) sprintf("prime-age men (%d-%d)", AGE_MIN, AGE_MAX)
                  else "all workers"
  SUFFIX  <- paste0(if (US_SOURCE == "oews") "oews_" else "",
                    if (IND_SCOPE == "formal") "formal_" else "",
                    if (RESTRICT) "primeage_male" else "allworkers")
  OUT_PNG <- file.path(OUT_DIR, sprintf("hist_llme1plus_empweighted_gemini_%s.png", SUFFIX))
  OUT_CSV <- file.path(OUT_DIR, sprintf("hist_llme1plus_empweighted_gemini_%s_stats.csv", SUFFIX))
  acs <- acs_raw
  message(sprintf("\n===== %s | india=%s | %s =====", US_SOURCE, IND_SCOPE, RESTRICT_LAB))

  emp_ind <- plfs %>%
    transmute(
      nco3   = str_sub(str_pad(as_chr(b5pt1q6_cperv1), 3, "left", "0"), 1, 3),
      status = as_chr(b5pt1q3_cperv1),
      sex    = as_num(b4q5_cperv1),
      age    = as_num(b4q6_perv1),
      w      = as_num(mult_cperv1) /
               ifelse(as_chr(nss_cperv1) == as_chr(nsc_cperv1), 100, 200) /
               as_num(no_qtr_cperv1)
    ) %>%
    # "formal" means regular salaried only (31)
    # restrict age to 16+ in india to be consistent with oews
    filter(status %in% IND_STATUS, age >= AGE_FLOOR,
           !RESTRICT | (sex == SEX_CODE & age >= AGE_MIN & age <= AGE_MAX),
           !is.na(nco3), nco3 != "", nco3 != "NA", !is.na(w)) %>%
    group_by(nco3) %>% summarise(emp = sum(w), .groups = "drop") %>%
    filter(emp > 0)

  message(sprintf("India employment: %.1fM across %d NCO-3 groups",
                  sum(emp_ind$emp) / 1e6, nrow(emp_ind)))

  if (US_SOURCE == "acs") {
    # US EMPLOYMENT ACS 2022, civilian employed
    # the occupation code is OCCSOC (SOC-2018)
    # restrict to EMPSTAT 1 = employed to filter employed
    emp_acs <- acs %>%
      transmute(perwt    = as_num(perwt),
                age      = as_num(age),
                sex      = as_num(sex),
                empstat  = as_num(empstat),
                empstatd = as_num(empstatd),
                occsoc   = as_chr(occsoc)) %>%
      filter(empstat == 1, !empstatd %in% c(13, 14, 15),
             !RESTRICT | (sex == SEX_CODE & age >= AGE_MIN & age <= AGE_MAX),
             !occsoc %in% c("", "0"), !is.na(perwt)) %>%
      group_by(occsoc) %>% summarise(emp = sum(perwt), .groups = "drop")

    message(sprintf("US employment: %.1fM across %d OCCSOC codes",
                    sum(emp_acs$emp) / 1e6, nrow(emp_acs)))

    # ACS OCCSOC needs to be converted to O*NET SOC-2018 6-digit. as some digits are missing for confidentiality reasons 
    soc_h <- read_excel(file.path(DL, "soc_structure_2018.xlsx"), skip = 8,
                        col_names = c("major", "minor", "broad", "detailed", "title")) %>%
      mutate(across(major:detailed, ~ str_remove(str_trim(as.character(.x)), "-"))) %>%
      fill(major, minor, broad) %>%
      filter(str_detect(detailed, "^\\d{6}$")) %>%
      select(detailed, broad, minor, major, title)

    stopifnot(nrow(soc_h) == 867,                                   # SOC-2018 detailed count, needs to complete checking all
              !any(is.na(soc_h$broad)), !any(is.na(soc_h$minor)), !any(is.na(soc_h$major)),
              all(str_sub(soc_h$major, 1, 2) == str_sub(soc_h$detailed, 1, 2)),
              all(str_sub(soc_h$minor, 1, 3) == str_sub(soc_h$detailed, 1, 3)),
              all(str_sub(soc_h$broad, 1, 3) == str_sub(soc_h$detailed, 1, 3)))

    onet      <- onet %>% mutate(soc6 = str_remove(str_sub(soc_code, 1, 7), "-")) #converting code to soc6, need to get rid of hyphen
    onet_socs <- sort(unique(onet$soc6))
    h         <- soc_h %>% filter(detailed %in% onet_socs)
    by_broad  <- split(h$detailed, h$broad) #broad soc
    by_minor  <- split(h$detailed, h$minor) #minor soc group
    by_major  <- split(h$detailed, h$major)#major soc group

    match_socs <- function(code) {
      if (str_detect(code, "[XY]"))                        # IPUMS hidden digits
        return(onet_socs[str_detect(onet_socs,
                 paste0("^", str_replace_all(code, "[XY]", "."), "$"))])
      if (code %in% onet_socs)        return(code)
      if (!is.null(by_broad[[code]])) return(by_broad[[code]])
      if (str_ends(code, "000") && !is.null(by_minor[[str_sub(code, 1, 3)]]))
                                      return(by_minor[[str_sub(code, 1, 3)]])
      if (!is.null(by_minor[[code]])) return(by_minor[[code]])
      if (str_ends(code, "0000") && !is.null(by_major[[str_sub(code, 1, 2)]]))
                                      return(by_major[[str_sub(code, 1, 2)]])
      character(0)
    }

    mapped <- emp_acs %>%
      mutate(soc6 = lapply(occsoc, match_socs), n_m = lengths(soc6))
    unassignable <- sum(mapped$emp[mapped$n_m == 0])

    emp_us <- mapped %>%
      filter(n_m > 0) %>%
      mutate(emp = emp / n_m) %>%          #as i map the hidden codes, i divide employment by no. of possible codes to get weight
      unnest(soc6) %>%
      group_by(soc6) %>% summarise(emp = sum(emp), .groups = "drop")

    message(sprintf("  mapped to %d of %d O*NET SOC codes; %.2fM unassignable (%.1f%%)",
                    nrow(emp_us), length(onet_socs), unassignable / 1e6,
                    100 * unassignable / sum(emp_acs$emp)))
    stopifnot(abs(sum(emp_us$emp) + unassignable - sum(emp_acs$emp)) < 1)   # reconciles

  } else {
    # BLS OEWS May 2022, national is based on SOC-2018, no need to split
    #however, 27 O*NET codes have no OEWS detailed row (OEWS publishes only their parent broad group)
    emp_us <- read_csv(file.path(BASE, "oews_2022_national_soc_employment.csv"),
                       col_types = cols(soc6 = col_character(), .default = col_guess())) %>%
      transmute(soc6, emp = as.numeric(tot_emp)) %>%
      filter(!is.na(emp), emp > 0)

    onet      <- onet %>% mutate(soc6 = str_remove(str_sub(soc_code, 1, 7), "-"))
    onet_socs <- sort(unique(onet$soc6))
    message(sprintf("US employment (OEWS): %.1fM over %d detailed SOC codes",
                    sum(emp_us$emp) / 1e6, nrow(emp_us)))
    message(sprintf("  covers %d of %d O*NET LLME1+ codes; %d dropped for want of an OEWS row",
                    length(intersect(onet_socs, emp_us$soc6)), length(onet_socs),
                    length(setdiff(onet_socs, emp_us$soc6))))
  }

  # to calculate fractional weighted employment, i divide by the no. of 8 digit nco occupations inside the 3 digit group
  #and then again by no. of tasks
  #   n_occ8      = 8-digit NCO occupations inside the 3-digit group
  #   n_tasks_occ = that occupation's own total task count
  # tasklength_nco_llme1plus.csv is already LLME1+-filtered, so the full 14,304-task
  # list comes from the exposure file.
  nco_occ <- read_csv(file.path(BASE, "nco_2015_ai_exposure.csv"),
                      col_types = cols(.default = col_character())) %>%
    distinct(occupation_code, task) %>%
    mutate(nco3 = str_sub(str_remove(occupation_code, fixed(".")), 1, 3)) %>%
    count(nco3, occupation_code, name = "n_tasks_occ") %>%
    group_by(nco3) %>% mutate(n_occ8 = n()) %>% ungroup()

  # now, i input the weighted value where w = emp / n_occ8 / n_tasks_occ
  ind_w <- ind %>%
    mutate(nco3 = str_sub(str_remove(soc_code, fixed(".")), 1, 3)) %>%
    left_join(emp_ind, by = "nco3") %>%
    left_join(nco_occ, by = c("nco3", "soc_code" = "occupation_code")) %>%
    mutate(w = emp / n_occ8 / n_tasks_occ) %>%
    filter(!is.na(w), w > 0) %>%
    transmute(source = LAB_IND, log_dur, w)
 # for onet, task weight is just emp / no. of tasks as we already divided employment by no. of mapped codes
  onet_w <- onet %>%
    left_join(emp_us, by = "soc6") %>%
    left_join(onet_all_n, by = "soc6") %>%
    mutate(w = emp / n_tasks_all) %>%
    filter(!is.na(w), w > 0) %>%
    transmute(source = LAB_ONET, log_dur, w)   # <- the source column bind_rows needs

  message(sprintf("weighted tasks: India %s (%.1fM of %.1fM employment, %.0f%% LLME1+ share)",
                  comma(nrow(ind_w)), sum(ind_w$w) / 1e6, sum(emp_ind$emp) / 1e6,
                  100 * sum(ind_w$w) / sum(emp_ind$emp)))
  message(sprintf("                O*NET %s (%.1fM of %.1fM employment, %.0f%% LLME1+ share)",
                  comma(nrow(onet_w)), sum(onet_w$w) / 1e6, sum(emp_us$emp) / 1e6,
                  100 * sum(onet_w$w) / sum(emp_us$emp)))

  dat <- bind_rows(ind_w, onet_w) %>%
    mutate(source = factor(source, levels = c(LAB_ONET, LAB_IND)))
  stopifnot(!any(is.na(dat$source)))

  # plot both unweighted and weighted
  panels <- c("unweighted", "weighted by employment")
  plot_dat <- bind_rows(
    dat %>% mutate(panel = panels[1], wt = 1),
    dat %>% mutate(panel = panels[2], wt = w)
  ) %>% mutate(panel = factor(panel, levels = panels))

  # stat
  stats_tbl <- plot_dat %>%
    group_by(panel, source) %>%
    summarise(n = n(), mean = w_mean(log_dur, wt), sd = w_sd(log_dur, wt),
              p10 = w_quantile(log_dur, wt, .10), p25 = w_quantile(log_dur, wt, .25),
              median = w_quantile(log_dur, wt, .50), p75 = w_quantile(log_dur, wt, .75),
              p90 = w_quantile(log_dur, wt, .90), .groups = "drop") %>%
    mutate(across(c(p10, p25, median, p75, p90), exp, .names = "{.col}_h"))

  write_csv(stats_tbl, OUT_CSV)
  print(as.data.frame(stats_tbl %>%
    select(panel, source, n, mean, sd, p10_h, median_h, p75_h, p90_h) %>%
    mutate(across(where(is.numeric), ~ round(.x, 3)))))

  med <- stats_tbl %>% select(panel, source, median, median_h)

  # Full data range
  XLIM <- range(plot_dat$log_dur) + c(-.3, .3)

  # Weighted kernel density for density graph
  
  BOUNDS <- c(log(1/60), log(672))   
  bin_breaks <- seq(XLIM[1], XLIM[2], length.out = 69)

  for (PLOT_TYPE in PLOT_TYPES) {
    lyr <- if (PLOT_TYPE == "density")
      geom_density(alpha = .25, linewidth = .8, bounds = BOUNDS, na.rm = TRUE)
    else
      geom_histogram(aes(y = after_stat(density)), breaks = bin_breaks,
                     position = "identity", alpha = .78, colour = NA)

    ymax <- max(ggplot_build(
      ggplot(plot_dat, aes(x = log_dur, weight = wt, colour = source)) +
        lyr + facet_wrap(~ panel))$data[[1]]$y, na.rm = TRUE)
    YLIM <- c(0, ymax * 1.18)
    med2 <- med %>% mutate(y_ind = YLIM[2] * .96, y_onet = YLIM[2] * .855)

    p <- ggplot(plot_dat, aes(x = log_dur, weight = wt, fill = source, colour = source)) +
      lyr +
      geom_vline(data = med2, aes(xintercept = median, colour = source),
                 linetype = "22", linewidth = .6, show.legend = FALSE) +
      geom_text(data = med2 %>% filter(source == LAB_IND),
                aes(x = median, y = y_ind, label = sprintf("median %.1f h", median_h)),
                colour = C_IND, hjust = 1.1, vjust = 1, size = 3, inherit.aes = FALSE) +
      geom_text(data = med2 %>% filter(source == LAB_ONET),
                aes(x = median, y = y_onet, label = sprintf("median %.1f h", median_h)),
                colour = C_ONET, hjust = -0.1, vjust = 1, size = 3, inherit.aes = FALSE) +
    facet_wrap(~ panel) +
    scale_fill_manual(values = setNames(c(C_ONET, C_IND), c(LAB_ONET, LAB_IND)), name = NULL) +
    scale_colour_manual(values = setNames(c(C_ONET, C_IND), c(LAB_ONET, LAB_IND)), name = NULL) +
    scale_x_continuous(breaks = hr_breaks, labels = hr_labels) +
    coord_cartesian(xlim = XLIM, ylim = YLIM, expand = FALSE) +
    labs(title = sprintf("LLME1+ only tasks: raw Gemini task length, India NCO-2015 vs O*NET (%s)",
                         paste0(if (US_SOURCE == "oews") "OEWS, " else "",
                                if (IND_SCOPE == "formal") "formal wage employees, " else "",
                                RESTRICT_LAB)),
         x = "task length (ln hours)", y = "density") +
    theme_minimal(base_size = 11) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank(),
          panel.grid.major.y = element_line(colour = GRID, linewidth = .3),
          strip.text = element_text(hjust = 0, size = 9.5, colour = INK2,
                                    margin = margin(b = 6)),
          plot.title = element_text(size = 13),
          plot.subtitle = element_text(size = 8.5, colour = INK2),
          axis.title = element_text(size = 9, colour = INK2),
          axis.text = element_text(colour = INK2),
          legend.position = "inside", legend.position.inside = c(.99, .97),
          legend.justification = c(1, 1),
          legend.background = element_blank(), legend.key.size = unit(10, "pt"),
          legend.text = element_text(size = 8.5))

    ggsave(sub("\\.png$", paste0("_", PLOT_TYPE, ".png"), OUT_PNG), p,
           width = 13.4, height = 5.2, dpi = 170)
  }
  message("wrote ", OUT_PNG)
  message("wrote ", OUT_CSV)
}

for (v in VARIANTS) run_variant(v$us, v$scope, v$restrict)
message(sprintf("\ndone: %d variant(s) written to %s", length(VARIANTS), OUT_DIR))
