library(jsonlite)
library(httr)
library(stringr)
library(purrr)

# ====== Custom operators ======

# %and%
# A custom operator that evaluates to TRUE if both of its arguments are TRUE,
# NA and NULL are treated as FALSE
# Not vectorized, only works with logicals
"%and%" <- function(x, y) {
    logical_x <- !is.na(x) && !is.null(x) && is.logical(x) && x
    logical_y <- !is.na(y) && !is.null(y) && is.logical(y) && y

    logical_x && logical_y
}

# %or%
# A custom operator that evaluates to TRUE
# if at least one of its arguments is TRUE,
# NA and NULL are treated as FALSE
# Not vectorized, only works with logicals
"%or%" <- function(x, y) {
    logical_x <- !is.na(x) && !is.null(x) && is.logical(x)  && x
    logical_y <- !is.na(y) && !is.null(y) && is.logical(y) && y

    logical_x || logical_y
}

# exists()
# A custom operator that evaluates to TRUE if the variable exists in the context
exists <- function(variable, context) {
    variable %in% names(context) && if (is.character(context[[variable]])) {
        context[[variable]] != ""
    } else {
        TRUE
    }
}

not <- function(variable, context) {
    if (exists(variable, context)) {
        value <- context[[variable]]
        return(is.na(value) || is.null(value) || (is.logical(value) && length(value) == 1 &&  !value))
    }

    TRUE
}

# ====== Fetching innformation on packs ======

# Get the JSON object from a URL
get_json_object <- function(url) {
  # default timeout is 13 sec.
  response <- GET(url, timeout(20))
  json <- content(response, as = "text")
  fromJSON(json)
}

# Get the name of the pack that a research output uses
get_pack_name <- function(research_output) {
    if (research_output$type == "pub") {
        "core-pubs"
    } else if (research_output$type == "software") {
        "core-software"
    } else if (research_output$type == "data") {
        "core-data"
    } else if (research_output$type == "meta") {
        "core-meta"
    } else {
        "unknown"
    }
}

# ====== Scoring ======

# Get the scoring information for a pack
get_scoring_information <- function(research_output) {
    get_json_object(paste0(
        "https://raw.githubusercontent.com/nicebread/RESQUE/main/packs/",
        get_pack_name(research_output),
        ".json"
    ))$scoring
}

# Evaluate a condition in a context
evaluate_condition_in_context <- function(condition, context) {
    processed_condition <- condition |>
        # replace "$<variable> =|= [<values>]" with "context$<variable> %in% c(<values>)"
        str_replace_all("(\\$[a-zA-Z0-9_]+)\\s*=\\|=\\s*\\[(.*?)\\]", "\\1 %in% c(\\2)") |>
        # replace "exists($<variable>)" with "exists(<variable>, context)"
        str_replace_all("exists\\(\\$(.*?)\\)", "exists('\\1', context)") |>
        # replace "!(<variable>)" with "not(<variable>, context)"
        str_replace_all("!\\(\\$([^=]*?)\\)", "not('\\1', context)") |>
        # replace "&&" with "%and%"
        str_replace_all("&&", "%and%") |>
        # replace "||" with "%or%"
        str_replace_all("\\|\\|", "%or%") |>
        # replace "===" with "=="
        str_replace_all("===", "==") |>
        # replace "!==" with "!="
        str_replace_all("!==", "!=") |>
        # replace "$<variable>"" with "context$<variable>"
        str_replace_all("\\$([a-zA-Z0-9_]+)", "context$\\1")

    result <- eval(parse(text = processed_condition))

    !is.na(result) &&
    !is.null(result) &&
    is.logical(result) &&
    length(result) == 1 &&
    result
}

# Score a single research output
# Returns a list with the following elements:
# - max_score: the maximum score that can be reached
# - score: the score that was reached
# - relative_score: the score that was reached divided by the maximum score
score <- function(research_output, verbose = FALSE) {
    # for debugging:
    # research_output <- research_outputs[[3]]
    scoring <- get_scoring_information(research_output)

    if (verbose == TRUE && is.null(scoring)) {
        print(paste0("scoring skipped (scoring == NULL)"))
    }

    indicators <- list()

    max_score <- 0
    reached_score <- 0

    for (indicator_index in seq_along(scoring)) {
        indicator <- scoring[[indicator_index]]
        # Get indicator name using the index
        indicator_name <- names(scoring)[indicator_index]

        if (verbose == TRUE) {
            print(paste0("indicator_index: ", indicator_index, " (", indicator_name, ")"))
        }

        # Handle 'not applicable' condition
        # Skip this indicator if the 'not applicable' condition is met
        if (evaluate_condition_in_context(
            indicator$not_applicable,
            research_output)) next

        max_score <- max_score + indicator$max

        # Evaluate each condition:
        # if it is met, add the corresponding value to the score
        values <- map2_dbl(
            indicator$points$condition,
            indicator$points$value,
            function(condition, value) {
                if (evaluate_condition_in_context(condition, research_output)) {
                    value
                } else {
                    0
                }
            }
        )

        # Apply the specified operation to the values
        indicator_score <- if (indicator$op == "sum") {
            sum(values)
        } else if (indicator$op == "select") {
            max(values)
        } else {
            0
        }

        # Add the indicator score to the reached score
        reached_score <- reached_score + indicator_score

        # Add the indicator score to the indicator score list
        indicators <- c(indicators, setNames(list(list(value = indicator_score, max = indicator$max)), indicator_name))
    }

    list(
        indicators = indicators,
        max_score = max_score,
        score = reached_score,
        relative_score = reached_score / max_score
    )
}

# Score multiple research outputs
# Returns a list with the following elements:
# - scores: a list of scores for each research output
# - scored_research_outputs: the number of research outputs that were scored
# - overall_score: the average score of all scored research outputs
score_all <- function(research_outputs, verbose = FALSE) {
    scores <- map(research_outputs, score, verbose = verbose)

    # Applicant requests manual processing if the max score is 0
    max_scores <- sapply(scores, function(x) x$max_score)
    valid_scores <- scores[max_scores > 0]

    list(
        scores = scores,
        scored_research_outputs = length(valid_scores),
        overall_score = mean(sapply(valid_scores, function(x) x$relative_score))
    )
}

# Score all research outputs from a file
# Reads the research outputs from the specified file and scores them (using score_all)
# Returns a list with the following elements:
# - scores: a list of scores for each research output
# - scored_research_outputs: the number of research outputs that were scored
# - overall_score: the average score of all scored research outputs
score_all_from_file <- function(path, verbose = FALSE) {
    research_outputs <- read_json(path)
    score_all(research_outputs, verbose = verbose)
}

# ====== Example ======

# Example: score multiple research outputs
# research_outputs <- read_json("profile/data/resque_1697454489129.json")
# score_all(research_outputs)

# Example: score a single research output
# research_output <- research_outputs[[1]]
# score(research_output)

# Example: score all research outputs from a file
# scores <- score_all_from_file("profile/data/resque_Felix.json", verbose = TRUE)