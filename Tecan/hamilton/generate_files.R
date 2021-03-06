source("hamilton/hamilton_values.R")
source("helpers/plates_helpers.R")

generate_var_files <- function(parts) {
        if (parts()$key %>% map_lgl(~ is.null(.x) || .x == "") %>% any()) return()
        
        paths <- "temp/" %>% str_c(pcr_csv_files) %>% set_names(names(pcr_csv_files))
        #PARTS
        #TODO: add position to the generated positions
        write.csv(parts() %>%
                          select(key, n_pcr, template_position) %>%
                          add_column(labware = pcr_labwares["parts"]),
                  file = paths["parts"], quote = TRUE, eol = "\r\n", row.names = FALSE)
        #COUNTS
        write.csv(tibble(total_pcr = sum(parts()$n_pcr),
                         n_parts = nrow(parts())),
                  file = paths["counts"], quote = TRUE, eol = "\r\n", row.names = FALSE)
        
        #PRIMERS
        write.csv(tibble(primer_key = c(parts()$l_primer, parts()$r_primer),
                         primer_position = c(parts()$l_primer_position, parts()$r_primer_position),
                         labware = pcr_labwares["primers"]),
                  file = paths["primers"], quote = TRUE, eol = "\r\n", row.names = FALSE)
        return(paths)
}

gdrive_update_file <- function(local_path, drive_url, progress) {
        progress$inc(.1, detail = str_interp("Uploading ${basename(local_path)}..."))
        drive_update(media = local_path,
                     file = as_id(drive_url))
}


generate_files <- function(parts, progress) {
        generate_var_files(parts) %>%
                walk2(drive_csv_files, ~ gdrive_update_file(.x, .y, progress))
}

generate_operator_sheets <- function(parts, progress) {
        user_name <- drive_user()$displayName
        pcr_date <- Sys.time() %>% as.POSIXlt(tz = "EST")
        first_parts <- str_c(parts()$key[1:min(3, nrow(parts()))], collapse = " ")
        file_name <- paste(user_name, pcr_date, first_parts, sep = "  |  ")
        desc_string <- str_interp("PCR Instruction by ${user_name} on ${pcr_date} with starting parts ${first_parts}")
        progress$inc(.1, detail = "Copying template sheet...")
        operator_ss_dbl <- drive_cp(file = as_id(pcr_template),
                 path = "Instructions/",
                 name = file_name)
        
        operator_ss <- gs_key(operator_ss_dbl$id)
        
        parts() %>%
                generate_plates() %>%
                #TODO: only update the part of the table that contains data...
                walk2(operator_ss$ws$ws_title,
                      ~ {progress$inc(.1, detail = str_interp("Filling ${.y}'s plate instructions..."))
                              gs_edit_cells(ss = operator_ss,
                                        ws = .y,
                                        input = .x,
                                        anchor = "B2",
                                        col_names = FALSE)
                              })
        
        walk(operator_ss$ws$ws_title, ~ {
                progress$inc(.1, detail = str_interp("Writing ${.x}'s title..."))
                gs_edit_cells(
                ss = operator_ss,
                ws = .x,
                input = str_c(desc_string, ": ", .x, collapse = ""),
                anchor = "B11"
        )})
        operator_ss_dbl$drive_resource[[1]]$webViewLink
}