# Golden fixture for DynamicNetworks.jl's panel constructor against R
# networkDynamic's networkDynamic(network.list = ...).
#
#   Rscript test/fixtures/r/panel_semantics.R > test/fixtures/panel_semantics.toml
#
# Random panels in the style of Sampson's samplk waves: K = 2..4 networks on
# the same vertex set, each wave keeping most ties of the previous one and
# adding a few, so ties persist, dissolve and re-form. Directed and undirected.
# The panels' spells are R's default (onsets 0..K-1, length 1), a shifted
# default (start = 10), or explicit onsets/termini with gaps, unequal lengths
# and point spells. For each case it records what networkDynamic stores: every
# vertex's and every dyad's activity spells, and the range of net.obs.period.
suppressMessages(library(networkDynamic))
# networkDynamic() prints its net.obs.period summary to stdout; keep it out of
# the fixture.
quiet <- function(expr) { invisible(capture.output(x <- suppressMessages(expr))); x }
seed <- 20261006L
set.seed(seed)

fmt_num <- function(x) {
  if (is.infinite(x)) return(if (x > 0) "Inf" else "-Inf")
  format(x, scientific = FALSE, trim = TRUE)
}
fmt_spells <- function(m) {
  if (is.null(m)) return("NULL")
  paste(apply(m, 1, function(r) paste(fmt_num(r[1]), fmt_num(r[2]))), collapse = ";")
}
q <- function(s) paste0('"', s, '"')
toml_strings <- function(v) if (length(v) == 0) "[]" else paste0("[", paste(q(v), collapse = ", "), "]")
toml_nums <- function(v) paste0("[", paste(sapply(v, fmt_num), collapse = ", "), "]")

n_cases <- 40L

# One wave from the previous one: keep each tie with probability 0.7, add
# new ties with probability p_new.
next_wave <- function(prev, n, directed, p_new) {
  m <- prev * (matrix(runif(n * n), n) < 0.7)
  m <- pmax(m, matrix(runif(n * n), n) < p_new)
  diag(m) <- 0
  if (!directed) { m[lower.tri(m)] <- 0; m <- pmax(m, t(m)) }
  m
}
edge_strings <- function(m, directed) {
  idx <- which(m == 1, arr.ind = TRUE)
  if (!directed) idx <- idx[idx[, 1] < idx[, 2], , drop = FALSE]
  if (nrow(idx) == 0) return(character(0))
  idx <- idx[order(idx[, 1], idx[, 2]), , drop = FALSE]
  paste(idx[, 1], idx[, 2])
}

cat('name = "panel_semantics"\n\n')
cat("[provenance]\n")
cat(sprintf('r_version = "%s"\n', paste(R.version$major, R.version$minor, sep = ".")))
cat(sprintf('networkDynamic_version = "%s"\n', as.character(packageVersion("networkDynamic"))))
cat(sprintf('network_version = "%s"\n', as.character(packageVersion("network"))))
cat(sprintf("seed = %d\n", seed))
cat('script = "test/fixtures/r/panel_semantics.R"\n')
cat(sprintf('date = "%s"\n', format(Sys.Date())))
cat(sprintf('dataset = "%d random panels of K = 2..4 networks on 5..18 vertices (samplk-style persistent ties; directed and undirected), with default, shifted and explicit panel spells"\n', n_cases))
cat("\n[tolerance]\n# Spell bounds are exact (integers and halves); comparisons are exact.\nexact = 0.0\n\n[values]\n")
cat(sprintf("n_cases = %d\n", n_cases))

for (g in seq_len(n_cases)) {
  directed <- g %% 3 != 0
  n <- if (g %% 4 == 1) 18L else sample(5:10, 1)
  K <- sample(2:4, 1)
  dens <- runif(1, 0.1, 0.3)
  waves <- list(next_wave(matrix(0, n, n), n, directed, dens))
  for (k in seq_len(K - 1)) waves[[k + 1]] <- next_wave(waves[[k]], n, directed, dens / 3)
  nets <- lapply(waves, function(m) network(m, directed = directed))

  kind <- c("default", "start", "explicit")[(g %% 3) + 1]
  if (kind == "default") {
    nd <- quiet(networkDynamic(network.list = nets))
    onsets <- numeric(0); termini <- numeric(0); start <- NA
  } else if (kind == "start") {
    start <- sample(c(-2, 5, 10), 1)
    nd <- quiet(networkDynamic(network.list = nets, start = start))
    onsets <- numeric(0); termini <- numeric(0)
  } else {
    lens <- sample(c(0, 0.5, 1, 2, 3), K, replace = TRUE)
    gaps <- sample(c(0, 0, 1, 2.5), K, replace = TRUE)
    onsets <- cumsum(c(0, head(lens + gaps, -1))) + sample(0:3, 1)
    termini <- onsets + lens
    start <- NA
    nd <- quiet(networkDynamic(network.list = nets, onsets = onsets, termini = termini))
  }
  obs <- range(unlist((nd %n% "net.obs.period")$observations))

  vact <- sapply(seq_len(n), function(v) fmt_spells(get.vertex.activity(nd, v = v)[[1]]))
  el <- as.matrix.network.edgelist(nd)
  eact <- character(0)
  if (nrow(el) > 0) for (r in seq_len(nrow(el))) {
    eid <- get.edgeIDs(nd, v = el[r, 1], alter = el[r, 2])[1]
    eact <- c(eact, sprintf("%d %d|%s", el[r, 1], el[r, 2],
                            fmt_spells(get.edge.activity(nd, e = eid)[[1]])))
  }

  cat(sprintf("\n[values.case_%d]\n", g))
  cat(sprintf("directed = %s\n", if (directed) "true" else "false"))
  cat(sprintf("n = %d\n", n))
  cat(sprintf('kind = "%s"\n', kind))
  if (kind == "start") cat(sprintf("start = %s\n", fmt_num(start)))
  if (kind == "explicit") {
    cat(sprintf("onsets = %s\n", toml_nums(onsets)))
    cat(sprintf("termini = %s\n", toml_nums(termini)))
  }
  for (k in seq_len(K)) cat(sprintf("wave_%d = %s\n", k, toml_strings(edge_strings(waves[[k]], directed))))
  cat(sprintf("n_waves = %d\n", K))
  cat(sprintf("observation_period = %s\n", toml_nums(obs)))
  cat(sprintf("vertex_activity = %s\n", toml_strings(vact)))
  cat(sprintf("edge_activity = %s\n", toml_strings(eact)))
}
