library(tidyverse)
library(jsonlite)
library(stringr)
library(purrr)

# Set working directory
input_dir <- ""
output_dir <- ""
setwd(input_dir)

# List all JSON files
json_files <- list.files(pattern = "\\.json$", full.names = FALSE)

# Define ordered tasks
task_order <- c(
  "robot-s1", "monster-s1", "face-scene-s1", "shelves", "cat", "ice-cream",
  "robot-s2", "monster-s2", "face-scene-s2", "socks", "mandala", "circus",
  "robot-s3", "monster-s3", "face-scene-s3", "continent", "fields", "house",
  "robot-s4", "monster-s4", "face-scene-s4", "vehicles", "cupcake", "sky",
  "robot-s5", "monster-s5", "face-scene-s5"
)

# Helper: parse file name
parse_filename <- function(filename) {
  pattern <- "^FLEX(\\d{6})_(sw|si)-([^-_]+(?:-[^_]+)?)_.*\\.json$"
  match <- str_match(filename, pattern)

  if (is.na(match[1, 1])) {
    return(NULL)
  }

  tibble(
    file       = filename,
    subject_id = paste0("sub-", match[1, 2]),
    type       = ifelse(match[1, 3] == "sw", "switch", "single"),
    task       = match[1, 4]
  )
}

# Parse and filter filenames
file_info <- map_dfr(json_files, parse_filename)

if (!"task" %in% colnames(file_info)) {
  stop("Parsing failed: 'task' column not found. Check filename patterns.")
}

file_info <- file_info %>%
  filter(task %in% task_order)

# Keep only "last-block" JSONs
select_last_block_file <- function(files) {
  last_block_files <- keep(files, function(f) {
    json_data <- tryCatch(fromJSON(f), error = function(e) NULL)
    !is.null(json_data) && json_data$type == "last-block"
  })

  if (length(last_block_files) > 0) {
    return(last_block_files[[1]])
  }
  return(NULL)
}

selected_files <- file_info %>%
  group_by(subject_id, task) %>%
  summarise(files = list(file), type = first(type), .groups = "drop") %>%
  mutate(file = map_chr(files, ~ {
    f <- select_last_block_file(.x)
    if (is.null(f)) NA_character_ else f
  })) %>%
  filter(!is.na(file)) %>%
  select(subject_id, task, type, file)

# Function to compute block numbers
compute_blocks <- function(switches) {
  block_num <- 1
  blocks <- integer(length(switches))

  for (i in seq_along(switches)) {
    if (switches[i] == "9") {
      if (i > 1) block_num <- block_num + 1
    }
    blocks[i] <- block_num
  }

  return(blocks)
}

# Function to extract trial data, compute LISAS, and save TSV
process_and_save <- function(file, subject_id, task, type) {
  json_data <- tryCatch(fromJSON(file), error = function(e) NULL)
  if (is.null(json_data)) {
    return(NULL)
  }

  data <- json_data$data
  lengths <- map_int(
    list(data$switches, data$tasks, data$timerUntilKeyPressed, data$wasAnswerCorrect),
    length
  )
  n_trials <- min(lengths)
  if (n_trials == 0) {
    return(NULL)
  }

  switches <- data$switches[1:n_trials]
  blocks <- compute_blocks(switches)
  task_labels <- data$tasks[1:n_trials]
  rt <- data$timerUntilKeyPressed[1:n_trials]
  correct <- as.logical(data$wasAnswerCorrect[1:n_trials])

  # Determine block type: "single" or "mixed"
  block_type <- map_chr(blocks, function(b) {
    task_set <- unique(task_labels[blocks == b])
    if (length(task_set) == 1) "single" else "mixed"
  })

  trial_df <- tibble(
    participant_id = subject_id,
    group          = type,
    switches       = switches,
    tasks          = task_labels,
    reaction_time  = rt,
    answer_correct = correct,
    block          = blocks,
    block_type     = block_type
  )

  ## --- Updated condition logic ---
  trial_df <- trial_df %>%
    mutate(condition = case_when(
      switches == 9 ~ NA_character_,
      block_type == "single" & switches == 0 ~ "single",
      block_type == "mixed" & switches == 0 ~ "repeat",
      block_type == "mixed" & switches == 1 ~ "switch",
      TRUE ~ NA_character_
    )) %>%
    arrange(condition)

  ## --- Add error column ---
  trial_df <- trial_df %>%
    mutate(error = ifelse(answer_correct, 0, 1))

  ## --- Overall SDs (still use full dataset) ---
  SRT <- sd(trial_df$reaction_time, na.rm = TRUE)
  SPE <- sd(trial_df$error, na.rm = TRUE)

  ## --- LISAS per non-NA condition only ---
  lisas_by_condition <- trial_df %>%
    filter(!is.na(condition)) %>%
    group_by(condition) %>%
    summarise(
      RTj = mean(reaction_time[answer_correct == TRUE], na.rm = TRUE),
      PEj = mean(error, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      LISAS = RTj + (SRT / SPE) * PEj
    )

  ## --- Debug print ---
  cat("\n===========================\n")
  cat("File:", file, "\n")
  cat("Subject:", subject_id, " | Task:", task, "\n")
  cat("SRT (RT SD):", round(SRT, 3), " | SPE (PE SD):", round(SPE, 3), "\n\n")

  for (cond in c("single", "repeat", "switch")) {
    cond_row <- lisas_by_condition[lisas_by_condition$condition == cond, ]
    if (nrow(cond_row) > 0) {
      cat(sprintf("Condition '%s':\n", cond))
      cat(sprintf("  RTj    = %.3f\n", cond_row$RTj))
      cat(sprintf("  PEj    = %.3f\n", cond_row$PEj))
      cat(sprintf("  LISAS  = %.3f\n\n", cond_row$LISAS))
    }
  }
  cat("===========================\n")

  ## --- Merge LISAS back ---
  trial_df <- left_join(
    trial_df,
    lisas_by_condition %>% select(condition, LISAS),
    by = "condition"
  ) %>%
    rename(lisas = LISAS)

  ## --- Save Output ---
  subject_dir <- file.path(output_dir, subject_id, "ses-training", "beh")
  dir.create(subject_dir, recursive = TRUE, showWarnings = FALSE)

  output_filename <- paste0(subject_id, "_ses-training_task-", task, "_beh.tsv")
  write_tsv(trial_df, file.path(subject_dir, output_filename))

  cat("Saved:", file.path(subject_dir, output_filename), "\n")
}

# Apply to all selected files
pwalk(selected_files, function(subject_id, task, type, file) {
  process_and_save(file, subject_id, task, type)
})
