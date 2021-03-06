
do_annual_metrics_multi_lake <- function(final_target, site_file_yml, ice_file_yml, n_cores, morphometry, temp_ranges, ...,
                                         site_file_regex = NULL, ice_file_regex = NULL, tmpdir_suffix = "") {
  
  site_files <- get_filenames_from_ind(site_file_yml)
  ice_files <- get_filenames_from_ind(ice_file_yml)
  
  # Each node on a Yeti normal partition has a max of 20 cores; nodes on Yeti UV partition do not have that same limit
  if(n_cores > 20) message("If using a node on the Yeti normal partition, you need to decrease n_cores to 20 or less")
  
  if(is.null(site_file_regex)) {
    site_file_regex <- "(pb0|pball|pgdl)_data_(.*)(.feather)"
  }
  if(is.null(ice_file_regex)) {
    ice_file_regex <- "pb0_(.*)_ice_flags.csv"
  }
  
  # Having `remake.yml` listed in "include" for these large task plans
  # is expensive. In order to decouple the task makefile from `remake.yml`
  # to simplify the dependencies and complexity, we need to save some of the 
  # target objects used as files. Each task will read these new files but
  # we don't think that will be an issue, even when doing it in parallel.
  morph_file <- sprintf("tasks_all_morphometry.rds")
  saveRDS(morphometry, morph_file)
  
  temp_ranges_file <- sprintf("temp_ranges.rds")
  saveRDS(temp_ranges, temp_ranges_file)
  
  # Define task table rows
  tasks <- tibble(wtr_filename = site_files) %>% 
    extract(wtr_filename, c('prefix','site_id','suffix'), site_file_regex, remove = FALSE) %>% 
    left_join(extract(tibble(ice_filename = ice_files), ice_filename, c('site_id'), ice_file_regex, remove = FALSE), by = "site_id") %>% 
    select(site_id, wtr_filename, ice_filename, prefix)
  
  model_type <- pull(tasks, prefix) %>% unique()
  
  # Define task table columns
  
  # I'm doing this because each toha task is slow running
  # and if `morphometry` changes, we don't want to have to re-run all of them,
  # just the ones where _their_ morphometry changed. So we are subsetting first. 
  split_morphometry <- scipiper::create_task_step(
    step_name = 'split_morphometry',
    target_name = function(task_name, step_name, ...){
      
      sprintf("3_summarize/tmp%s/%s_morphometry.rds.ind", tmpdir_suffix, task_name)
    },
    command = function(task_name, ...){
      sprintf("split_and_save_morphometry(target_name, '%s', I('%s'))", morph_file, task_name)
    } 
  )
  
  calc_annual_metrics <- create_task_step(
    step_name = 'calc_annual_metrics',
    target_name = function(task_name, step_name, ...) {
      sprintf("3_summarize/tmp%s/%s_%s_annual_thermal_metrics.rds.ind", tmpdir_suffix, model_type, task_name)
    },
    command = function(..., task_name, steps) {
      task_info <- filter(tasks, site_id == task_name)
      psprintf("calculate_annual_metrics_per_lake(", 
               "out_ind = target_name,",
               "site_id = I('%s')," = task_name,
               "site_file = '%s'," = task_info$wtr_filename,
               "ice_file = '%s'," = task_info$ice_filename,
               "temp_ranges_file = '%s'," = temp_ranges_file,
               "morphometry_ind = '%s'," = steps[["split_morphometry"]]$target_name,
               # Doesn't actually print to console with `loop_tasks` but let's you see if you are troubleshooting individual files
               "verbose = I(TRUE))" 
      )
    }
  )
  
  # Create the task plan
  task_plan <- create_task_plan(
    task_names = tasks$site_id,
    task_steps = list(split_morphometry, calc_annual_metrics),
    final_steps = c('calc_annual_metrics'),
    add_complete = FALSE)
  
  # Create the task remakefile
  task_makefile <- sprintf('3_summarize_%s_metric_tasks.yml', model_type)
  create_task_makefile(
    task_plan = task_plan,
    makefile = task_makefile,
    sources = c(...),
    packages = c('tidyverse', 'purrr', 'readr', 'scipiper'),
    final_targets = final_target,
    finalize_funs = 'combine_thermal_metrics',
    as_promises = TRUE,
    tickquote_combinee_objects = TRUE)
  
  # Build the tasks
  loop_tasks(task_plan = task_plan,
             task_makefile = task_makefile,
             num_tries = 1,
             n_cores = n_cores)
  
  # Clean up files created
  
  # Remove the temporary target from remake's DB; it won't necessarily be a unique  
  #   name and we don't need it to persist, especially since killing the task yaml
  scdel(sprintf("%s_promise", basename(final_target)), remake_file=task_makefile)
  # Delete task makefile since it is only needed internally for this function and  
  #   not needed at all once loop_tasks is complete. Also delete temporary files
  #   saved in order to decouple task makefile from `remake.yml`.
  file.remove(task_makefile, morph_file, temp_ranges_file)
  
}

combine_thermal_metrics <- function(target_name, ...) {
  purrr::map(list(...), function(ind) readRDS(as_data_file(ind))) %>% purrr::reduce(bind_rows) %>% readr::write_csv(target_name)
}

split_and_save_morphometry <- function(out_ind, morphometry_file, site_id) {
  data_file <- as_data_file(out_ind)
  morphometry <- readRDS(morphometry_file)
  saveRDS(morphometry[[site_id]], data_file)
  sc_indicate(ind_file = out_ind, data_file = data_file)
}
