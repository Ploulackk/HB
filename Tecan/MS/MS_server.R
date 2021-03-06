library(shiny); library(rvest)
library(purrrlyr);

ms_server <- function(input, output, session) {
    source("ms/ms_extract.R"); source("ms/ms_functions.R")
    source("registry/registry_helpers.R"); source("helpers/strings.R")
    source("helpers/plates_helpers.R"); source("mongo/tags.R")
    source("ms/ms_csv.R")

    options(shiny.trace = FALSE)
    user <- drive_user()$displayName
    ns <- session$ns

    #### INIT & FILE HANDLING ####
    source("helpers/ui_generics/select_file_server.R")
    source("helpers/general.R"); source("protocols/protocols_module.R")
    source("mongo/db_values.R"); source("helpers/mongo_helpers.R")
    tab_name <-  str_extract(session$ns(""), "^\\w+")
    selected <- reactiveVal()
    ms_folder <- get_drive_url(session, tab_name)
    ms_progress <- shiny::Progress$new()

    ms <- callModule(module = select_file,
                     id = "files",
                     progress = ms_progress,
                     drive_url = ms_folder,
                     selected = selected
    )

    ms$tbl <- reactiveVal(NULL)

    obtain_file_data(
        ms$go_file,
        "MS",
        file_container = ms,
        dat_container = ms$tbl,
        extract_function = extract_ms
    )

    #### PROTOCOLS ####
    ms_p <- callModule(module = protocols_handler,
                       id = "ms",
                       file_container = ms,
                       data_container = ms$tbl,
                       selected = selected,
                       db = ms_db)


    #### GENERATE MS RUN ####
    pos_96 <- generate_96_pos()
    pos_48 <- generate_48_pos()
    dics <- reactiveValues()
    ms_samples <- reactiveVal(
        tibble(
            label = character(),
            strain = character(),
            plasmid = character(),
            identifier = character(),
            group_id = character(),
            pos = character(),
            tags = character(),
            plate = character(),
            plate_note = character(),
            url = character(),
            is_48 = logical()
        )
    )

    tab_plates <- reactiveVal("")

    ms_edit <- reactiveValues(
        is_ongoing = FALSE
    )

    db_tags <- db_from_environment(session, "tags")

    if (!exists("registry")) {
        registry <- NULL
    }

    #Debug
    observeEvent(ms_samples(), {
        print(ms_samples())
    })

    observeEvent(input$create_ms, {

        if (is.null(registry)) {
            print("Loading Registry")
            registry <<- registry_key_names(registry_url, registry_sheets)
        }

        dics$plasmids <- registry %>%
            select(1:3, type) %>%
            filter(type == "Plasmids") %>%
            pull(KEY)

        if (is.null(dics$strains)) {
            print("Loading Strains")
            dics$strains <- get_strains()
        }

        check_ongoing_edit(get_drive_url(session,"ms_ongoing_edit"), user, ms_edit)

        if (ms_edit$is_ongoing) {
            new_ms_modal(ns, ms$protocols()$name, ms_edit$experiment)
            ms_samples(ms_edit$data %>%
                           arrange(str_extract(pos, "[A-Z]"),
                                   str_extract(pos, "\\d+")
                           )
            )

            #Open the tabs
            plates_info <- ms_edit$data %>%
                group_by(plate) %>%
                summarise(
                    is_48 = unique(is_48),
                    url = unique(url),
                    plate_note = unique(plate_note)
                )

            plates_info %>%
                by_row(..f = ~
                {
                    #Add each tab's UI
                    appendTab(inputId = "new_ms_tabs",
                              tab = new_ms_tab(ns = ns,
                                               current_tab = .$plate,
                                               is_48 = .$is_48,
                                               plate_note = .$plate_note,
                                               url = .$url),
                              select = TRUE
                    )
                    tab_plates(append(tab_plates(), .$plate))

                    # Start the observers related to each plate
                    start_plate_observers(session = session, input = input,
                                          ms_samples = ms_samples, plate = .$plate,
                                          ms_edit = ms_edit, dics = dics, db_tags = db_tags, csv_name = csv_name)
                }
                )

            # Fill the samples
            ms_samples()  %>%
                by_row(..f = ~ insert_sample(session = session,
                                             label = .x$label,
                                             dics = dics,
                                             available_positions = if (.x$is_48) pos_48 else pos_96,
                                             ms_samples,
                                             db = db_tags,
                                             sample = .x
                )
                )
        } else {
            new_ms_modal(ns = ns, experiment_names = ms$protocols()$name)
        }
    })

    observeEvent(input$new_ms_plate, {

        plates <- paste0("Plate_", 2:8)
        new_plate <- plates[!plates %in% tab_plates()][1]

        add_plate(ns, session, input, tab_plates, new_plate, ms_samples, ms_edit, dics, db_tags, csv_name)
    })

    observeEvent(input$use_plate_1, {
        add_plate(ns = ns, session = session, input = input, tab_plates = tab_plates,
                  new_plate = "Plate_1", ms_samples = ms_samples, ms_edit = ms_edit,
                  dics = dics, db_tags = db_tags, csv_name = csv_name)
    })

    csv_name <- reactive({
        experiment <- input$new_ms_experiment
        csv_name <- str_interp("exp_${experiment}_${user}_note_${input$file_note}.csv")
    })

    observeEvent(input$new_ms_ok, {

        date <- Sys.time() %>%
            force_tz(tzone = "America/Montreal")

        file_name <- paste("temp/", input$file_note, user, "UNITARY", date, ".csv", sep = "_")

        generate_sample_list_csv(ms_samples(), input, user) %>%
            write.csv(file = file_name,
                      quote = TRUE,
                      eol = "\r\n",
                      row.names = FALSE,
                      na = "")

        upload_drbl <- drive_upload(media = file_name,
                                    path = ms$protocols() %>%
                                        filter(name == input$new_ms_experiment) %>%
                                        pull(ms_csv_folder_url) %>%
                                        as_id()
        )
        if (is_dribble(upload_drbl)) {
            drive_trash(ms_edit$drbl)
            reset_ms_edit(ms_samples, tab_plates)
        }
    })

    observeEvent(input$new_ms_cancel, {
        reset_ms_edit(ms_samples, tab_plates)
    })

    #### DB STORAGE ####

    ms_db <- db_from_environment(session, collection = "ms")
    file_record <- reactiveVal()

    observeEvent(ms$go_file(), {

        record <- mongo_file_entry(ms_db, ms$id(), tab_name)

        if (!record$entry_exists && record$delay < 100) {
            date <- Sys.time() %>%
                force_tz(tzone = "America/Montreal") %>%
                jsonlite::toJSON(POSIXt = "mongo",
                                 pretty = TRUE) %>%
                str_remove("\\[[\\n|\\s]+") %>%
                str_remove("[\\n|\\s]+\\]")


            ms_dat_json <- jsonlite::toJSON(x = ms$tbl(),
                                            dataframe = "rows",
                                            POSIXt = "mongo",
                                            pretty = TRUE)

            query <- str_interp('{
                                            "_id" : "${ms$id()}",
                                            "name": "${ms$file_dribble()$name}",
                                            "date_created": ${date},
                                            "data": ${ms_dat_json}}'
            )
browser()
            insert_log <- ms_db$insert(data = query)
        }
        file_record(record)
    })


    #### MS DATA DIPLAY ####

    stored_choices <- reactiveVal(NULL)
    display_tbl <- reactiveVal()
    last_click <- reactiveVal(NULL)

    observeEvent(ms$go_file(), {
        #Reset stored choices
        stored_choices(NULL)

        #Reset the select all button
        updateCheckboxInput(session, "select_all", value = FALSE)

        updateCheckboxGroupInput(session = session,
                                 inputId = "samples",
                                 choices = unique(ms$tbl()$Name),
                                 selected = unique(ms$tbl()$Name)[1]
        )
        updateCheckboxGroupInput(session = session,
                                 inputId = "molecules",
                                 choices = unique(ms$tbl()$Molecule),
                                 selected = unique(ms$tbl()$Molecule)
        )

    })


    observeEvent(input$select_all, {

        if (input$select_all) {
            stored_choices(input$samples)


            non_0_conc_choices <- ms$tbl() %>%
                filter(Molecule %in% input$molecules,
                       Concentration > 0) %>%
                pull(Name) %>%
                unique()

            updateCheckboxGroupInput(session = session,
                                     inputId = "samples",
                                     selected = non_0_conc_choices)

        } else if (!is.null(stored_choices())) {
            updateCheckboxGroupInput(session = session,
                                     inputId = "samples",
                                     selected = stored_choices())
        }
    }, ignoreInit = TRUE)

    unaggregated_tbl <- reactive({
        if (any(is.null(c(input$samples, input$molecules)))) return()

        res_tbl <- ms$tbl() %>%
            select(c(Name, Molecule, Concentration)) %>%
            group_by(Name, Molecule) %>%
            arrange(Name) %>%
            filter(Name %in% input$samples) %>%
            filter(Molecule %in% input$molecules)

        return(res_tbl)
    })

    observeEvent(unaggregated_tbl(), {
        display_tbl(unaggregated_tbl() %>%
                        summarise(sd = sd(Concentration),
                                  Mean = mean(Concentration)) %>%
                        ungroup() %>%
                        mutate(cut_off = TRUE)
        )
    }, priority = -1)


    observeEvent(input$click, {
        if (!is.null(input$click)) last_click(input$click)
    })

    #On file change reset the value selection from click
    observeEvent(ms$go_file(), {
        last_click(NULL)
    })

    clicked_sample <- eventReactive(last_click(), {

        if (is.null(last_click())) return(NULL)

        click_x <- last_click()$x
        n_molecules <- length(input$molecules)
        splits <- seq(1/(2 * n_molecules), 1 - 1/(2 * n_molecules), 1/n_molecules)

        sample_lvls <- display_tbl()$Name %>%
            as_factor() %>%
            levels()
        name <- sample_lvls[round(click_x)]

        molecule_lvls <- display_tbl()$Molecule %>%
            as_factor() %>%
            droplevels() %>%
            levels()

        x <- click_x - round(click_x) + 1/2

        molecule_name <- molecule_lvls[which.min(abs(splits - x))]

        value <- display_tbl() %>%
            filter(Molecule == molecule_name & Name == name) %>%
            pull(Mean)

        list(name = name,
             molecule = molecule_name,
             value = value)

    }, ignoreNULL = FALSE)

    observeEvent(clicked_sample(), {

        if (is.null(clicked_sample()$value)) {
            display_tbl(
                display_tbl() %>%
                    mutate(cut_off = TRUE)
            )
        } else {

            display_tbl(
                display_tbl() %>%
                    mutate(cut_off = if_else(
                        Mean >= clicked_sample()$value,
                        TRUE,
                        FALSE,
                        missing = FALSE)
                    )
            )
        }
    })

    file_title <- renderText({
        validate(
            need(ms$tbl(), message = "no ms data")
        )

        molecules <- ms$tbl()$Molecule %>%
            unique() %>%
            str_c(collapse = " ")

        date_range <- min(ms$tbl()$Time,na.rm = TRUE) %>%
            paste(
                max(ms$tbl()$Time,na.rm = TRUE) %>%
                    (function(x) {paste(hour(x), minute(x), second(x), sep = ":")})
            )

        paste0(molecules, " ~ ", date_range)
    })



    barplot_scale <- reactive({
        ifelse(input$log_scale, "log1p", "identity")
    })

    output$bar <- renderPlot({
        if (is.null(display_tbl()) || nrow(display_tbl()) == 0) return()

        g <- ggplot(display_tbl()) +
            aes(x = Name, y = Mean, fill = Molecule) +
            geom_bar(position = "dodge",
                     stat = "identity",
                     aes(alpha = cut_off %>%
                             factor(levels = c(FALSE, TRUE))
                     )
            ) +
            geom_errorbar(position = position_dodge(.9),
                          aes(ymax = Mean + sd,
                              ymin = Mean - sd,
                              width = .15)) +
            theme(axis.text.x = element_text(angle = 60,
                                             hjust = .8,
                                             size = 10,
                                             face = if_else(display_tbl()$cut_off,"bold", "plain"))) +
            scale_y_continuous(trans = barplot_scale()) +
            scale_fill_discrete(limits = levels(ms$tbl()$Molecule)) +
            scale_alpha_discrete(drop = FALSE, guide = "none")

        if (!is.null(clicked_sample()$value)) {
            g + geom_hline(yintercept = clicked_sample()$value)
        } else {
            g
        }


    })

    output$table <- renderTable({
        if (input$display_raw) {
            unaggregated_tbl()
        }  else display_tbl()
    })


    # Print the name of the x value
    output$x_value <- renderText({
        if (is.null(clicked_sample())) return()
        else {
            HTML("You've selected sample <code>", clicked_sample()$name, "</code>",
                 "<br>and molecule <code>", clicked_sample()$molecule,"</code>",
                 "<br>of value <code>", round(clicked_sample()$value,2), "</code>")
        }
    })

    output$save_csv <- downloadHandler(
        filename = function() {
            paste0(ms$file_dribble()$name, ".csv")
        },
        content = function(file) {
            write_csv(
                ms$tbl() %>%
                    select(Name, Molecule, Concentration),
                file,
                na = "0")
        }
    )
}