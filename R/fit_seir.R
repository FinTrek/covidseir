#' Fit a Stan SEIR model
#'
#' This function fits a Stan SEIR model to one or more sets of COVID-19 case
#' data. See [project_seir()] for making predictions/projections.
#'
#' @param daily_cases Either a vector of daily new cases if fitting to a single
#'   data type or a matrix of case data if fitting to multiple data types. Each
#'   data type should be in its own column. Can have NA values (will be ignored
#'   in likelihood). A vector will be turned into a one column matrix.
#' @param obs_model Type of observation model.
#' @param forecast_days Number of days into the future to forecast. The model
#'   will run faster with fewer forecasted days. It is recommended to set this
#'   to 0 here and use [project_seir()] for projections.
#' @param time_increment Time increment for ODEs and Weibull delay-model
#'   integration in units of days. Larger numbers will run faster,
#'   possibly at the expense of accuracy.
#' @param samp_frac_fixed A vector (or matrix) of sampled fractions. Should be
#'   of dimensions: `nrow(daily_cases) + forecast_days` (rows) by
#'   `ncol(daily_cases` (columns). A vector will be turned into a one column
#'   matrix.
#' @param samp_frac_type How to treat the sample fraction. Fixed, estimated, a
#'   constrained random walk, or segmented. Only applies to the first data type
#'   column. The other data types must always have a fixed sample fraction
#'   currently.
#' @param samp_frac_seg A vector of sample fraction segment indexes of length
#'   `daily_cases` + `forecast_days`. Should start at 1. Applies if
#'   `samp_frac_type = "segmented"`.
#' @param f_seg A vector of segment indexes of length `daily_cases` +
#'   `forecast_days`. The segment index values should start at 0 to represent
#'   the fixed "no social distancing" value `f0` from the `pars` argument.
#'   Doesn't come into play until after `end_decline` day.
#' @param days_back Number of days to go back for the Weibull case-delay
#'   integration. Should be sufficiently large that the results do not change.
#' @param R0_prior Lognormal log mean and SD for the R0 prior.
#' @param phi_prior SD of `1/sqrt(phi) ~ Normal(0, SD)` prior, where NB2(mu,
#'   phi) and `Var(Y) = mu + mu^2 / phi`. See the Stan
#'   \href{https://github.com/stan-dev/stan/wiki/Prior-Choice-Recommendations}{Prior
#'   Choice Recommendations}.
#' @param f_prior Beta mean and SD for the `f` parameters. FIXME: all `f`
#'   parameters must have the same prior currently. This will be fixed.
#' @param e_prior Beta mean and SD for the `e` (derived) parameter.
#'   `e` represents the fraction of people who are social distancing.
#' @param samp_frac_prior `samp_frac` prior if `samp_frac_type` is "estimated"
#'   or "rw" or "segmented". In the case of the random walk, this specifies the
#'   initial state prior. The two values correspond to the mean and SD of a Beta
#'   distribution. Only applies to first time series.
#' @param start_decline_prior Lognormal log mean and SD for the parameter
#'   representing the day that social distancing starts ramping in
#'   (`start_decline`).
#' @param end_decline_prior Lognormal log mean and SD for the parameter
#'   representing the day that the social distancing ramp finishes being ramped
#'   in (`end_decline`).
#' @param f_ramp_rate An exponential rate for the initial social distancing
#'   ramp. A value near 0 result in a linear ramp. A value > 0 results in a ramp
#'   that starts slowly and ends quickly. A value < 0 results in a ramp that
#'   starts quickly and ends slowly. See the Stan model in
#'   `inst/stan/seir.stan`.
#' @param rw_sigma The fixed standard deviation on the optional `samp_frac`
#'   random walk.
#' @param seed MCMC seed for [rstan::stan()].
#' @param chains Number of MCMC chains for [rstan::stan()].
#' @param iter MCMC iterations per chain for [rstan::stan()].
#' @param N_pop Number of people in population.
#' @param pars A named numeric vector of fixed parameter values.
#' @param i0_prior Infected people infected at initial point in time. Lognormal
#'   log mean and SD for the parameter. Note that the default is set up for BC.
#'   You may need to use a lower prior for other regions.
#' @param state_0 Initial state: a named numeric vector.
#' @param save_state_predictions Include the state predictions? `y_hat` Will
#'   make the resulting model object much larger.
#' @param delay_scale Weibull scale parameter for the delay in reporting. If
#'   there are multiple datatypes then this should be a vector of the same
#'   length as the data types.
#' @param delay_shape Weibull shape parameter for the delay in reporting. Same
#'   format as for `delay_scale`.
#' @param ode_control Control options for the Stan ODE solver. First is relative
#'   difference, then absolute difference, and then maximum iterations. These
#'   can likely be left as is.
#' @param ... Other arguments to pass to [rstan::sampling()] / [rstan::stan()].
#' @export
#' @return A named list object
#' @examples
#' \donttest{
#' # Example daily case data:
#' cases <- c(
#'   0, 0, 1, 3, 1, 8, 0, 6, 5, 0, 7, 7, 18, 9, 22, 38, 53, 45, 40,
#'   77, 76, 48, 67, 78, 42, 66, 67, 92, 16, 70, 43, 53, 55, 53, 29,
#'   26, 37, 25, 45, 34, 40, 35
#' )
#'
#' # Example assumed sampling fractions of positive cases:
#' s1 <- c(rep(0.1, 13), rep(0.2, length(cases) - 13))
#'
#' # To use parallel processing with multiple chains:
#' # options(mc.cores = parallel::detectCores() / 2)
#'
#' # Only using 100 iterations and 1 chain for a quick example:
#' m <- fit_seir(
#'   cases,
#'   iter = 100,
#'   chains = 1,
#'   samp_frac_fixed = s1
#' )
#' print(m)
#' names(m)
#' names(m$post) # from rstan::extract(m$fit)
#'
#' # Use tidybayes if you'd like:
#' # post_tidy <- tidybayes::spread_draws(m$fit, c(y_rep, mu)[day, data_type])
#'
#' # Add hospitalization data and estimate 2 sample-fraction blocks
#' # for the reported cases:
#' samp_frac_seg <- c(rep(1, 13), rep(2, length(cases) - 13))
#'
#' s2 <- rep(0.07, 42) # Assuming 7\% of positive individuals are hospitalized
#' hosp <- c(
#'   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 11, 9, 4,
#'   7, 19, 23, 13, 11, 3, 13, 21, 14, 17, 29, 21, 19, 19, 10, 6,
#'   11, 8, 11, 8, 7, 6
#' )
#' m2 <- fit_seir(
#'   daily_cases = cbind(cases, hosp),
#'   iter = 100,
#'   chains = 1,
#'   samp_frac_type = "segmented", # `samp_frac_type` affects the first data type only
#'   samp_frac_seg = samp_frac_seg,
#'   samp_frac_fixed = cbind(s1, s2), # s1 is ignored and could be anything
#'   delay_scale = c(9.8, 11.2),
#'   delay_shape = c(1.7, 1.9),
#' )
#' print(m2)
#'
#' # Estimate a second f_s segment:
#' f_seg <- c(rep(0, 14), rep(1, 20), rep(2, length(cases) - 20 - 14))
#' m3 <- fit_seir(
#'   cases,
#'   iter = 100,
#'   chains = 1,
#'   f_seg = f_seg,
#'   samp_frac_fixed = s1
#' )
#' print(m3)
#' }
#'
fit_seir <- function(daily_cases,
                     obs_model = c("NB2", "Poisson"),
                     forecast_days = 0,
                     time_increment = 0.25,
                     samp_frac_fixed = NULL,
                     samp_frac_type = c("fixed", "estimated", "rw", "segmented"),
                     samp_frac_seg = NULL,
                     f_seg = c(0, rep(1, nrow(daily_cases) + forecast_days - 1)),
                     days_back = 45,
                     R0_prior = c(log(2.6), 0.2),
                     phi_prior = 1,
                     f_prior = c(0.4, 0.2),
                     e_prior = c(0.8, 0.05),
                     samp_frac_prior = c(0.4, 0.2),
                     start_decline_prior = c(log(15), 0.05),
                     end_decline_prior = c(log(22), 0.05),
                     f_ramp_rate = 0,
                     rw_sigma = 0.1,
                     seed = 42,
                     chains = 4,
                     iter = 2000,
                     N_pop = 5.1e6,
                     pars = c(D = 5, k1 = 1 / 5,
                       k2 = 1, q = 0.05,
                       ud = 0.1, ur = 0.02, f0 = 1.0
                     ),
                     i0_prior = c(log(8), 1),
                     state_0 = c(
                       E1_frac = 0.4,
                       E2_frac = 0.1,
                       I_frac = 0.5,
                       Q_num = 0,
                       R_num = 0,
                       E1d_frac = 0.4,
                       E2d_frac = 0.1,
                       Id_frac = 0.5,
                       Qd_num = 0,
                       Rd_num = 0
                     ),
                     save_state_predictions = FALSE,
                     delay_scale = 9.85,
                     delay_shape = 1.73,
                     ode_control = c(1e-7, 1e-6, 1e6),
                     ...) {
  obs_model <- match.arg(obs_model)
  obs_model <-
    if (obs_model == "Poisson") {
      0L
    } else if (obs_model == "NB2") {
      1L
    }
  x_r <- pars

  samp_frac_type <- match.arg(samp_frac_type)
  n_samp_frac <-
    if (samp_frac_type == "fixed") {
      0L
    } else if (samp_frac_type == "estimated") {
      1L
    } else if (samp_frac_type == "segmented") {
      max(samp_frac_seg)
    } else { # random walk:
      nrow(daily_cases)
    }

  if (names(x_r[1]) == "N" || names(state_0[1]) == "S") {
    stop(
      "It appears your code is set up for an older version ",
      "of the package. ",
      "(`names(x_r[1]) == 'N' || names(state_0[1]) == 'S')",
      call. = FALSE)
  }
  stopifnot(
    names(x_r) ==
      c("D", "k1", "k2", "q", "ud", "ur", "f0")
  )
  x_r <- c(c("N" = N_pop), x_r)
  stopifnot(
    names(state_0) == c("E1_frac", "E2_frac", "I_frac", "Q_num", "R_num", "E1d_frac",
      "E2d_frac", "Id_frac", "Qd_num", "Rd_num")
  )

  # Checks and type conversions:
  if (!is.matrix(daily_cases)) daily_cases <- matrix(daily_cases, ncol = 1)
  if (!is.matrix(samp_frac_prior)) samp_frac_prior <- matrix(samp_frac_prior, ncol = 1)
  if (!is.matrix(samp_frac_fixed)) samp_frac_fixed <- matrix(samp_frac_fixed, ncol = 1)
  stopifnot(length(delay_scale) == ncol(daily_cases))
  stopifnot(length(delay_shape) == ncol(daily_cases))

  days <- seq(1, nrow(daily_cases) + forecast_days)
  last_day_obs <- nrow(daily_cases)
  time <- seq(-30, max(days), time_increment)

  x_i <- c("last_day_obs" = last_day_obs)
  f_seg <- stats::setNames(f_seg, paste0("f_seg_id_", seq_along(f_seg)))
  x_i <- c(x_i, c("n_f_s" = length(f_seg)), f_seg)

  # find the equivalent time of each day (end):
  time_day_id <- vapply(days, get_time_id, numeric(1), time = time)
  # find the equivalent time of each day (start):
  time_day_id0 <- vapply(days, get_time_day_id0, numeric(1),
    time = time, days_back = days_back
  )

  stopifnot(nrow(samp_frac_fixed) == length(days))
  stopifnot(ncol(samp_frac_fixed) == ncol(daily_cases))

  beta_sd <- f_prior[2]
  beta_mean <- f_prior[1]
  beta_shape1 <- get_beta_params(beta_mean, beta_sd)$alpha
  beta_shape2 <- get_beta_params(beta_mean, beta_sd)$beta

  if (samp_frac_type == "fixed") {
    samp_frac_prior <- c(1, 1) # fake
  }

  samp_frac_prior_trans <- c(
    get_beta_params(samp_frac_prior[1], samp_frac_prior[2])$alpha,
    get_beta_params(samp_frac_prior[1], samp_frac_prior[2])$beta
  )
  e_prior_trans <- c(
    get_beta_params(e_prior[1], e_prior[2])$alpha,
    get_beta_params(e_prior[1], e_prior[2])$beta
  )

  daily_cases_stan <- daily_cases
  if (sum(is.na(daily_cases)) > 0) {
    if (9999999L %in% daily_cases) {
      stop("covidseir uses `9999999` as a 'magic' number for `NA`.", call. = FALSE)
    }
    daily_cases_stan[is.na(daily_cases_stan)] <- 9999999L # magic number for NA
    contains_NAs <- 1L
  } else {
    contains_NAs <- 0L
  }

  if (is.null(samp_frac_seg)) {
    samp_frac_seg <- rep(1, length(days))
  }

  x_r <- c(x_r, "f_ramp_rate" = f_ramp_rate)
  x_r <- c(x_r, "imported_cases" = 0) # not used until projections
  x_r <- c(x_r, "imported_window" = 1) # not used until projections
  stan_data <- list(
    T = length(time),
    days = days,
    daily_cases = daily_cases_stan,
    J = ncol(daily_cases),
    N = length(days),
    S = length(unique(f_seg)) - 1, # - 1 because of 0 for fixed f0 before soc. dist.
    y0_vars = state_0,
    t0 = min(time) - 0.000001,
    time = time,
    n_x_r = length(x_r),
    x_r = x_r,
    n_x_i = length(x_i),
    x_i = x_i,
    delay_shape = array(delay_shape),
    delay_scale = array(delay_scale),
    samp_frac_fixed = samp_frac_fixed,
    samp_frac_seg = samp_frac_seg,
    samp_frac_type = if (samp_frac_type == "segmented") 4L else 1L, # FIXME
    time_day_id = time_day_id,
    time_day_id0 = time_day_id0,
    R0_prior = R0_prior,
    phi_prior = phi_prior,
    i0_prior = i0_prior,
    f_prior = c(beta_shape1, beta_shape2),
    samp_frac_prior = samp_frac_prior_trans,
    e_prior = e_prior_trans,
    start_decline_prior = start_decline_prior,
    end_decline_prior = end_decline_prior,
    n_samp_frac = n_samp_frac,
    rw_sigma = rw_sigma,
    priors_only = 0L,
    last_day_obs = last_day_obs,
    obs_model = obs_model,
    contains_NAs = contains_NAs,
    ode_control = ode_control,
    est_phi = if (obs_model %in% 1L) ncol(daily_cases) else 0L
  )
  # map_estimate <- rstan::optimizing(
  #   stanmodels$seir,
  #   data = stan_data
  # )
  initf <- function(stan_data) {
    R0 <- stats::rlnorm(1, R0_prior[1], R0_prior[2]/2)
    i0 <- stats::rlnorm(1, i0_prior[1], i0_prior[2]/2)
    start_decline <- stats::rlnorm(1, start_decline_prior[1], start_decline_prior[2]/2)
    end_decline <- stats::rlnorm(1, end_decline_prior[1], end_decline_prior[2]/2)
    f <- stats::rbeta(
      1,
      get_beta_params(f_prior[1], f_prior[2]/4)$alpha,
      get_beta_params(f_prior[1], f_prior[2]/4)$beta
    )
    ur <- get_ur(e_prior[1], pars[["ud"]])
    f_s <- array(f, dim = stan_data$S)
    init <- list(R0 = R0, f_s = f_s, i0 = i0,
      ur = ur,
      start_decline = start_decline, end_decline = end_decline)
    init
  }
  pars_save <- c("R0", "f_s", "i0", "e", "ur", "phi", "mu", "y_rep",
    "start_decline", "end_decline", "samp_frac")
  if (save_state_predictions) pars_save <- c(pars_save, "y_hat")
  set.seed(seed)
  fit <- rstan::sampling(
    stanmodels$seir,
    data = stan_data,
    iter = iter,
    chains = chains,
    init = function() initf(stan_data),
    seed = seed, # https://xkcd.com/221/
    pars = pars_save,
    ... = ...
  )
  post <- rstan::extract(fit)
  structure(list(
    fit = fit, post = post, phi_prior = phi_prior, R0_prior = R0_prior,
    f_prior = f_prior, obs_model = obs_model,
    e_prior_trans = e_prior_trans,
    start_decline_prior = start_decline_prior,
    end_decline_prior = end_decline_prior,
    samp_frac_fixed = samp_frac_fixed, state_0 = state_0,
    daily_cases = daily_cases, days = days, time = time,
    last_day_obs = last_day_obs, pars = x_r,
    f2_prior_beta_shape1 = beta_shape1,
    f2_prior_beta_shape2 = beta_shape2,
    stan_data = stan_data, days_back = days_back
  ), class = "covidseir")
}

get_beta_params <- function(mu, sd) {
  var <- sd^2
  alpha <- ((1 - mu) / var - 1 / mu) * mu^2
  beta <- alpha * (1 / mu - 1)
  list(alpha = alpha, beta = beta)
}

get_time_id <- function(day, time) max(which(time <= day))

get_time_day_id0 <- function(day, time, days_back) {
  # go back `days_back` or to beginning if that's negative time:
  check <- time <= (day - days_back)
  if (sum(check) == 0L) {
    1L
  } else {
    max(which(check))
  }
}

get_ur <- function(e, ud) (ud - e * ud) / e
getu <- function(f, r) (r - f * r) / f
