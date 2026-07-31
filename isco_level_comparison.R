suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(readr); library(stringr)
  library(readxl); library(ggplot2)
})

ROOT <- "/Users/karentao/MIT Dropbox/Karen Tao/AI_and_Development_MIT_FutureTech/Karen/05 Task Length Exercise"
BASE <- file.path(ROOT, "00 source")

DEV_COUNTRY <- "india"          #I can replicate this for other countries too, later

DEV_SPEC <- list(
  india = list(
    label      = "India",
    file       = file.path(BASE, "tasklength_nco_llme1plus.csv"),
    isco4_from = function(x) str_sub(str_remove_all(x, "[^0-9]"), 1, 4),
    exposure   = NULL
    # this file is only LLME1+ that went through the gemini predictions
  )
)
DEV <- DEV_SPEC[[DEV_COUNTRY]]
OUT <- file.path(ROOT, sprintf("03 isco_level_comparison_%s_figures", DEV_COUNTRY))
dir.create(OUT, showWarnings = FALSE)

C_DEV <- "#eb6834"; C_ONET <- "#2a78d6"; C_POS <- "#e34948"; C_NEG <- "#2a78d6"
GRID  <- "#e3e2dd"; INK2 <- "#52514e"

say <- local({ buf <- character(0)
function(fmt = NULL, ...) {
  if (is.null(fmt)) return(buf)
  s <- if (length(list(...))) sprintf(fmt, ...) else fmt
  cat(s, "\n"); buf <<- c(buf, s); invisible(NULL)
}})

audit <- local({ rows <- list()
function(step = NULL, rows_in = NA, rows_out = NA, note = "") {
  if (is.null(step)) return(bind_rows(rows))
  rows[[length(rows) + 1]] <<- tibble(step = step, rows_in = rows_in,
                                      rows_out = rows_out,
                                      rows_lost = rows_in - rows_out, note = note)
  say("  [audit] %-32s %7s -> %7s  (lost %5s)  %s", step,
      format(rows_in, big.mark = ","), format(rows_out, big.mark = ","),
      format(rows_in - rows_out, big.mark = ","), note)
}})

say(strrep("=", 78))
say("LLME1+ AVERAGE TASK LENGTH BY ISCO-08 SUB-MAJOR (2-DIGIT) AND MINOR (3-DIGIT)")
say("  developing side : %s, raw Gemini (`duration`)", DEV$label)
say("  O*NET side      : raw Gemini (`gemini_hours` from rawonet.xlsx)")
say(strrep("=", 78))

# nco
load_dev <- function(spec) {
  d <- read_csv(spec$file, col_types = cols(soc_code = col_character(),
                                            .default = col_guess()))

  # hard stop on 0 or negative or n/a for duration, as taking log can lead to issue
  stopifnot(!any(is.na(d$duration)), all(is.finite(d$duration)),
            min(d$duration) > 0, max(d$duration) <= 672 + 1e-9)

  # under 1 min rows
  n_sub <- sum(d$duration < 1 / 60 - 1e-9)
  if (n_sub > 0)
    say("  note: %d row(s) average below the 1-min prompt floor (min %.3f min)",
        n_sub, min(d$duration) * 60)

  # ln is always recomputed from the raw gemini `duration` at the end of this function.
  d <- d %>% select(-any_of(c("log_dur", "est_log_dur")))

  # Put the rows in estimation run order if the file records it explicitly
  if (!is.null(spec$order_by)) {
    stopifnot(spec$order_by %in% names(d))
    d <- d %>% arrange(.data[[spec$order_by]])
  }

  # gemini estimated a few tasks twice due a bug, so only keep the latest run
  ndup <- nrow(d) - nrow(distinct(d, soc_code, task))
  if (ndup > 0) {
    n_pre <- nrow(d)
    d <- d %>% group_by(soc_code, task) %>%
      filter(row_number() == n()) %>% ungroup()
    audit("dev: drop superseded task rows", n_pre, nrow(d),
          "same (code, task) estimated twice, kept last run")
  }

  n0 <- nrow(d)
  if (!is.null(spec$exposure)) {
    ex <- read_csv(spec$exposure$file, col_types = cols(.default = col_character())) %>%
      mutate(llme_n = as.numeric(str_extract(llme, "\\d$"))) %>%
      select(all_of(unname(spec$exposure$by)), llme_n) %>% distinct()
    d <- d %>% inner_join(ex, by = spec$exposure$by)
    audit("dev: join exposure labels", n0, nrow(d), "key = (code, task)")
    n1 <- nrow(d); d <- d %>% filter(llme_n >= 1)
    audit("dev: keep LLME1+", n1, nrow(d), "")
  } else {
    say("already an LLME1+ pool")
  }
  d %>% mutate(isco4 = spec$isco4_from(soc_code),
               isco3 = str_sub(isco4, 1, 3),
               isco2 = str_sub(isco4, 1, 2),
               ln_dur = log(duration))                # recompute
}

dev <- load_dev(DEV)
say("%s: %s LLME1+ tasks, %d ISCO-4, %d ISCO-3, %d ISCO-2 groups", DEV$label,
    format(nrow(dev), big.mark = ","), n_distinct(dev$isco4),
    n_distinct(dev$isco3), n_distinct(dev$isco2))

# onet
onet <- read_excel(file.path(BASE, "rawonet.xlsx"), sheet = 1,
                   col_types = c("text", "text", "text",
                                 "numeric", "numeric", "numeric", "numeric")) %>%
  mutate(across(c(soc_code, task), str_trim))
stopifnot(nrow(distinct(onet, soc_code, task)) == nrow(onet),
          !any(is.na(onet$gemini_hours)),
          abs(min(onet$gemini_hours) - 1 / 60) < 1e-9,
          abs(max(onet$gemini_hours) - 672) < 1e-9)

# only use the tasks with task lengths (onet 29.2)
lengths_csv <- read_csv(file.path(BASE, "all_onet_task_lengths.csv"),
                        col_types = cols(.default = col_guess())) %>%
  transmute(task_id = `Task ID`, soc_code = str_trim(`O*NET-SOC Code`),
            task = str_trim(Task), Title, legacy_log_dur = log_dur)
n0 <- nrow(onet)
onet <- onet %>% inner_join(lengths_csv, by = c("soc_code", "task"))
audit("onet: pin to all_onet_task_lengths", n0, nrow(onet), "key = (soc_code, task)")
stopifnot(nrow(onet) == 18796, !any(duplicated(onet$task_id)))

# LLME1+ 
oe <- read_csv(file.path(BASE, "onet_ai_exposure.csv"),
               col_types = cols(.default = col_character())) %>%
  mutate(llme_n = as.integer(str_extract(llme, "\\d$"))) %>%
  filter(llme_n >= 1) %>% distinct(occupation_code, task)
n1 <- nrow(onet)
onet <- onet %>%
  semi_join(oe, by = c("soc_code" = "occupation_code", "task" = "task")) %>%
  mutate(ln_raw = log(gemini_hours),                  
         soc18  = str_remove(str_sub(soc_code, 1, 7), "-"))
audit("onet: keep LLME1+", n1, nrow(onet), "dropped rows are all LLME0")
stopifnot(nrow(onet) == 14012)

say("O*NET: %s LLME1+ tasks, %d SOC-2018 codes; raw mean %.4f ln, sd %.4f, median %.2f h",
    format(nrow(onet), big.mark = ","), n_distinct(onet$soc18),
    mean(onet$ln_raw), sd(onet$ln_raw), median(onet$gemini_hours))

# crosswalk O*NET-SOC -> SOC-2010 -> ISCO-08
# BLS sheets carry a few title//contact rows above the real header
hdr_row <- function(path, needle, sheet = 1, n_max = 20) {
  probe <- read_excel(path, sheet = sheet, col_names = FALSE, n_max = n_max,
                      .name_repair = "minimal")
  i <- which(apply(probe, 1, function(r) any(grepl(needle, r, fixed = TRUE))))[1]
  if (is.na(i))
    stop(sprintf("no header row containing '%s' in the first %d rows of %s",
                 needle, n_max, basename(path)))
  i
}

isco_soc_xls <- file.path(BASE, "isco_soc_crosswalk.xls")
bls_hdr <- hdr_row(isco_soc_xls, "2010 SOC Code",
                   sheet = "2010 SOC to ISCO-08", n_max = 12)
soc_isco_bls <- read_excel(isco_soc_xls,
                           sheet = "2010 SOC to ISCO-08", skip = bls_hdr - 1,
                           col_types = "text") %>%
  transmute(soc10 = str_remove(str_trim(`2010 SOC Code`), "-"),
            isco4 = str_trim(`ISCO-08 Code`)) %>%
  filter(str_detect(soc10, "^\\d{6}$"), str_detect(isco4, "^\\d{4}$")) %>% distinct()

soc_isco <- bind_rows(
  as.data.frame(iscoCrosswalks::soc10_isco08) %>%
    transmute(soc10 = as.character(soc10), isco4 = as.character(isco08)),
  soc_isco_bls) %>%
  distinct()
say("SOC-2010 -> ISCO-08: %d links over %d SOC codes (BLS xls %d + iscoCrosswalks, unioned)",
    nrow(soc_isco), n_distinct(soc_isco$soc10), n_distinct(soc_isco_bls$soc10))

to_isco <- function(d) {
  d %>% group_by(soc) %>% mutate(w1 = 1 / n()) %>% ungroup() %>%
    inner_join(soc_isco, by = "soc10", relationship = "many-to-many") %>%
    group_by(soc, soc10) %>% mutate(w2 = 1 / n()) %>% ungroup() %>%
    group_by(soc, isco4) %>% summarise(w = sum(w1 * w2), .groups = "drop")
}


# BLS 2010<->2018 table
soc_1018_xlsx <- file.path(BASE, "soc_2010_to_2018_crosswalk.xlsx")
hdr <- hdr_row(soc_1018_xlsx, "2018 SOC Code")
link <- read_excel(soc_1018_xlsx, skip = hdr - 1) %>%
  transmute(soc   = str_remove(`2018 SOC Code`, "-"),
            soc10 = str_remove(`2010 SOC Code`, "-")) %>%
  filter(!is.na(soc), !is.na(soc10)) %>% distinct() %>% to_isco() %>%
  rename(soc18 = soc)

chk <- link %>% group_by(soc18) %>% summarise(tot = sum(w), .groups = "drop")
say("Crosswalk (BLS 2018 table only): %d SOC codes to ISCO-08. Weights sum to 1 for %d/%d",
    nrow(chk), sum(abs(chk$tot - 1) < 1e-9), nrow(chk))


onet_l <- onet %>% inner_join(link, by = "soc18", relationship = "many-to-many") %>%
  mutate(isco3 = str_sub(isco4, 1, 3), isco2 = str_sub(isco4, 1, 2))
unmatched <- onet %>% anti_join(link, by = "soc18")
audit("onet: place on ISCO", nrow(onet), n_distinct(onet_l$task_id),
      sprintf("%d SOC codes unmatched", n_distinct(unmatched$soc18)))
write_csv(unmatched %>% count(soc18, Title, name = "n_tasks"),
          file.path(OUT, "onet_soc_unmatched_to_isco.csv"))
write_csv(audit(), file.path(OUT, "join_audit.csv"))

labs <- as.data.frame(iscoCrosswalks::isco) %>%
  transmute(code = as.character(code), label = as.character(preferredLabel))

compare_level <- function(lvl) {
  d_g <- dev %>% group_by(code = .data[[lvl]]) %>%
    summarise(n_dev = n(), dev_raw = mean(ln_dur), dev_am = mean(duration),
              .groups = "drop")
  o_g <- onet_l %>% group_by(code = .data[[lvl]]) %>%
    # w_onet is the pure fractional task count. each task's 1/n shares summed
    summarise(w_onet = sum(w), n_onet_tasks = n_distinct(task_id),
              onet_raw = weighted.mean(ln_raw, w),
              onet_am  = weighted.mean(gemini_hours, w), .groups = "drop")
  full_join(d_g, o_g, by = "code") %>% left_join(labs, by = "code") %>%
    mutate(gap = dev_raw - onet_raw, ratio = exp(gap),
           dev_h = exp(dev_raw), onet_h = exp(onet_raw),
           # Arithmetic mean
           dev_amln = log(dev_am), onet_amln = log(onet_am),
           gap_am = dev_amln - onet_amln, ratio_am = exp(gap_am)) %>%
    arrange(code)
}


# geometric: mean of log hours
# arithmetic: log of mean of hours
MEANS <- list(
  list(dev = "dev_raw",  onet = "onet_raw",  gap = "gap",
       lab = "geometric mean",  sfx = ""),
  list(dev = "dev_amln", onet = "onet_amln", gap = "gap_am",
       lab = "arithmetic mean", sfx = "_am")
)

for (lvl in c("isco2", "isco3")) {
  g  <- compare_level(lvl)
  dg <- substr(lvl, 5, 5)
  nm <- if (lvl == "isco2") "sub-major (2-digit)" else "minor (3-digit)"
  
  both <- g %>% filter(!is.na(dev_raw), !is.na(onet_raw))
  say("")
  say(strrep("-", 78))
  say("ISCO-08 %s — %d groups shown (%d on both sides, %d O*NET-only, %d %s-only)",
      nm, nrow(g), nrow(both), sum(is.na(g$dev_raw)), sum(is.na(g$onet_raw)), DEV$label)
  say(strrep("-", 78))
  say("  %s mean %.3f ln | O*NET mean %.3f ln | mean gap %+.3f (%.2fx)",
      DEV$label, mean(both$dev_raw), mean(both$onet_raw), mean(both$gap),
      exp(mean(both$gap)))
  say("  Pearson r %.3f | Spearman rho %.3f | slope %.3f | %s longer in %d/%d groups",
      cor(both$dev_raw, both$onet_raw),
      cor(both$dev_raw, both$onet_raw, method = "spearman"),
      coef(lm(dev_raw ~ onet_raw, both))[2], DEV$label,
      sum(both$gap > 0), nrow(both))
  say("  arithmetic: %s %.2f h | O*NET %.2f h | mean gap %+.3f ln (%.2fx) | %s longer in %d/%d",
      DEV$label, mean(both$dev_am), mean(both$onet_am), mean(both$gap_am),
      exp(mean(both$gap_am)), DEV$label, sum(both$gap_am > 0), nrow(both))

  show <- g %>% transmute(code, label = str_trunc(label, 44), n_dev,
                          w_onet = round(w_onet, 1), dev_h = round(dev_h, 2),
                          onet_h = round(onet_h, 2), gap = round(gap, 3),
                          x = round(ratio, 2), dev_am = round(dev_am, 2),
                          onet_am = round(onet_am, 2), x_am = round(ratio_am, 2))
  say(paste(capture.output(print(as.data.frame(show), row.names = FALSE)), collapse = "\n"))
  write_csv(g, file.path(OUT, sprintf("isco%s_llme1plus_comparison.csv", dg)))
  
  dot_plot <- function(gg, ord_lab, fname, ms) {
    pd <- gg %>% mutate(lab = factor(sprintf("%s  %s", code, str_trunc(label, 44)),
                                     levels = sprintf("%s  %s", code, str_trunc(label, 44))),
                        x_dev = .data[[ms$dev]], x_onet = .data[[ms$onet]])
    p <- ggplot(pd) +

      geom_segment(aes(y = lab, yend = lab, x = x_onet, xend = x_dev),
                   colour = GRID, linewidth = 1.1, na.rm = TRUE) +
      geom_point(aes(y = lab, x = x_onet, colour = "O*NET raw Gemini"),
                 size = 2.6, na.rm = TRUE) +
      geom_point(aes(y = lab, x = x_dev,
                     colour = sprintf("%s raw Gemini", DEV$label)),
                 size = 2.6, na.rm = TRUE) +
      scale_colour_manual(values = setNames(c(C_ONET, C_DEV),
                                            c("O*NET raw Gemini", sprintf("%s raw Gemini", DEV$label))),
                          breaks = c("O*NET raw Gemini",
                                     sprintf("%s raw Gemini", DEV$label)), name = NULL) +
      scale_y_discrete(limits = levels(pd$lab), drop = FALSE) +
      # Calendar hours
      scale_x_continuous(breaks = log(c(1/60, 1/6, 1, 4, 8, 24, 168, 720)),
                         labels = c("1 min", "10 min", "1 hr", "4 hr", "8 hr",
                                    "1 day", "1 wk", "1 mo")) +
      labs(title = sprintf("LLME1+ %s task length by ISCO-08 %s — %s",
                           ms$lab, nm, ord_lab),
           subtitle = sprintf("%s vs O*NET, raw uncalibrated Gemini (%s of hours, natural log)",
                              DEV$label, ms$lab),
           x = sprintf("%s task length (log scale)", ms$lab), y = NULL) +
      theme_minimal(base_size = 9) +
      theme(panel.grid.minor = element_blank(), panel.grid.major.y = element_blank(),
            legend.position = "top", axis.text.y = element_text(colour = INK2))
    ggsave(file.path(OUT, fname), p, width = 9.5,
           height = max(3.2, 0.23 * nrow(gg) + 1.8), dpi = 170, limitsize = FALSE)
  }

  gap_plot <- function(gg, ms) {
    # those groups without gaps are not drawn
    pg <- gg %>% filter(!is.na(.data[[ms$gap]])) %>%
      mutate(gap_v = .data[[ms$gap]],
             lab = sprintf("%s  %s", code, str_trunc(label, 44))) %>%
      arrange(gap_v) %>% mutate(lab = factor(lab, levels = lab))
    q <- ggplot(pg, aes(y = lab, x = gap_v, fill = gap_v > 0)) +
      geom_col(width = .68) +
      geom_vline(xintercept = 0, colour = INK2, linewidth = .4) +
      scale_fill_manual(values = c("TRUE" = C_POS, "FALSE" = C_NEG), guide = "none") +
      labs(title = sprintf("%s minus O*NET, ISCO-08 %s (LLME1+, %s, raw Gemini both sides)",
                           DEV$label, nm, ms$lab),
           subtitle = sprintf("positive = %s estimates run longer", DEV$label),
           x = "gap (ln hours)", y = NULL) +
      theme_minimal(base_size = 9) +
      theme(panel.grid.minor = element_blank(), panel.grid.major.y = element_blank(),
            axis.text.y = element_text(colour = INK2))
    ggsave(file.path(OUT, sprintf("isco%s_gap%s.png", dg, ms$sfx)), q,
           width = 8.5, height = max(3.2, 0.23 * nrow(pg) + 1.6), dpi = 170,
           limitsize = FALSE)
  }

  # ggplot draws the first factor level at the BOTTOM, so descending arrange() puts
  # the largest value at the top of the chart.
  for (ms in MEANS) {
    dot_plot(g %>% arrange(desc(code)),          "in ISCO code order",
             sprintf("isco%s_dots_by_isco%s.png", dg, ms$sfx), ms)
    dot_plot(g %>% arrange(.data[[ms$onet]]),    "longest US tasks first",
             sprintf("isco%s_dots_by_us%s.png", dg, ms$sfx), ms)
    dot_plot(g %>% arrange(.data[[ms$dev]]),     sprintf("longest %s tasks first", DEV$label),
             sprintf("isco%s_dots_by_%s%s.png", dg, DEV_COUNTRY, ms$sfx), ms)
    gap_plot(g, ms)
  }
}

writeLines(say(), file.path(OUT, "isco_level_report.txt"))
say("")
say("wrote %s", OUT)
