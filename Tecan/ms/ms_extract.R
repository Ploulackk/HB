library(rvest); library(lubridate)


extract_ms <- function(input_file, dribble) {#Are we using that dribble at all?
    download_drive_file(input_file = input_file) %>%
        read_xml() %>%
        extract_ms_data()
}

extract_ms_data <- function(xml) {
    samples <- xml %>%
        xml_nodes("SAMPLE")

    samples_info <- samples %>%
        map(xml_attrs) %>%
        map_df(as.list) %>%
        mutate(Time = paste0(createdate,"_",createtime) %>%
                   dmy_hms(tz = "America/Montreal")) %>%
        mutate(
            Tags = str_split(desc, ", "),
            Strain = str_extract(name, "^\\w+?(?=_)"),
            Plasmid = str_extract(name, "PLAS-[\\d]+"),
            Identifier = str_extract(name, "(?<=_)[^_]\\w+(?=_\\d+(_G-\\d+)?$)")
        ) %>%
        select(Name = name,type, sampleid = id, Strain, Plasmid, Identifier, Tags, Time)

    samples %>%
        xml_nodes("COMPOUND") %>%
        map(xml_attrs) %>%
        map_df(as.list) %>%
        select(sampleid, Molecule = name) %>%
        add_column(
            Concentration = samples %>%
                xml_nodes("PEAK") %>%
                map(xml_attrs) %>%
                map_df(as.list) %>%
                pull(analconc)
        ) %>%
        mutate(Concentration = as.double(Concentration),
               Molecule = as.factor(Molecule)) %>%
        left_join(samples_info, by = "sampleid") %>%
        filter(tolower(type) == "analyte") %>%
        select(-type)
}
