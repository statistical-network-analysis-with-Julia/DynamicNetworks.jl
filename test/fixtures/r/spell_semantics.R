# Golden fixture for DynamicNetworks.jl: spell semantics against R networkDynamic.
#
#   Rscript test/fixtures/r/spell_semantics.R > test/fixtures/spell_semantics.toml
#
# Random activation/deactivation sequences on small directed and undirected
# networks -- vertex and edge activations (interval, point, adjacent and
# overlapping spells), deactivations (including of elements that were never
# activated, which R treats as active by default), and base-network edges and
# vertices that never receive a spell. For each case it records what R
# networkDynamic stores (activate.* merges spells on insertion), what
# network.extract returns at instants and over intervals (rule any/all), what
# network.collapse returns for interval queries, and what
# reconcile.edge.activity(mode = "reduce.to.vertices") leaves on each edge.
# Everything uses R's defaults, in particular active.default = TRUE.
suppressMessages(library(networkDynamic))
seed <- 20261002L
set.seed(seed)

fmt_num <- function(x) {
  if (is.infinite(x)) return(if (x > 0) "Inf" else "-Inf")
  format(x, scientific = FALSE, trim = TRUE)
}
fmt_spells <- function(m) {
  if (is.null(m) || (nrow(m) == 1 && is.infinite(m[1, 1]) && m[1, 1] > 0)) return("NULL")
  paste(apply(m, 1, function(r) paste(fmt_num(r[1]), fmt_num(r[2]))), collapse = ";")
}
q <- function(s) paste0('"', s, '"')
toml_strings <- function(v) paste0("[", paste(q(v), collapse = ", "), "]")

n <- 5L
n_cases <- 80L
draw_time <- function() sample(0:9, 1) + sample(c(0, 0, 0.5), 1)
draw_spell <- function() {
  on <- draw_time()
  c(on, on + sample(c(0, 0, 1, 1, 2, 3, 5), 1))
}

cat('name = "spell_semantics"\n\n')
cat("[provenance]\n")
cat(sprintf('r_version = "%s"\n', paste(R.version$major, R.version$minor, sep = ".")))
cat(sprintf('networkDynamic_version = "%s"\n', as.character(packageVersion("networkDynamic"))))
cat(sprintf('network_version = "%s"\n', as.character(packageVersion("network"))))
cat(sprintf("seed = %d\n", seed))
cat('script = "test/fixtures/r/spell_semantics.R"\n')
cat(sprintf('date = "%s"\n', format(Sys.Date())))
cat(sprintf('dataset = "%d random cases on %d vertices (directed and undirected): activation/deactivation sequences with point, adjacent and overlapping spells; some vertices and edges never receive a spell"\n', n_cases, n))
cat("\n[tolerance]\n# Spell bounds are exact grid values (multiples of 0.5); comparisons are exact.\nexact = 0.0\n\n[values]\n")
cat(sprintf("n_cases = %d\n", n_cases))

for (g in seq_len(n_cases)) {
  directed <- g %% 4 != 0
  nw <- network.initialize(n, directed = directed)
  # base edges: random dyads, some never get a spell (active by default)
  pairs <- unique(t(replicate(7, sort(sample(1:n, 2)))))
  if (directed) pairs <- t(apply(pairs, 1, function(p) if (runif(1) < 0.5) rev(p) else p))
  pairs <- unique(pairs)
  for (r in seq_len(nrow(pairs))) add.edge(nw, pairs[r, 1], pairs[r, 2])
  ops <- character(0)
  # vertex operations: some vertices untouched
  for (v in 1:n) {
    k <- sample(0:3, 1, prob = c(0.3, 0.3, 0.25, 0.15))
    for (i in seq_len(k)) {
      s <- draw_spell()
      if (runif(1) < 0.2) {
        if (s[2] == s[1]) s[2] <- s[1] + 1
        nw <- deactivate.vertices(nw, onset = s[1], terminus = s[2], v = v)
        ops <- c(ops, sprintf("dv %d 0 %s %s", v, fmt_num(s[1]), fmt_num(s[2])))
      } else {
        nw <- activate.vertices(nw, onset = s[1], terminus = s[2], v = v)
        ops <- c(ops, sprintf("av %d 0 %s %s", v, fmt_num(s[1]), fmt_num(s[2])))
      }
    }
  }
  # edge operations: some edges untouched
  for (eid in seq_len(nrow(pairs))) {
    k <- sample(0:4, 1, prob = c(0.2, 0.3, 0.25, 0.15, 0.1))
    for (i in seq_len(k)) {
      s <- draw_spell()
      if (runif(1) < 0.2) {
        if (s[2] == s[1]) s[2] <- s[1] + 1
        nw <- deactivate.edges(nw, onset = s[1], terminus = s[2], e = eid)
        ops <- c(ops, sprintf("de %d %d %s %s", pairs[eid, 1], pairs[eid, 2], fmt_num(s[1]), fmt_num(s[2])))
      } else {
        nw <- activate.edges(nw, onset = s[1], terminus = s[2], e = eid)
        ops <- c(ops, sprintf("ae %d %d %s %s", pairs[eid, 1], pairs[eid, 2], fmt_num(s[1]), fmt_num(s[2])))
      }
    }
  }
  vsp <- sapply(1:n, function(v) fmt_spells(get.vertex.activity(nw, v = v)[[1]]))
  esp <- sapply(seq_len(nrow(pairs)), function(e) fmt_spells(get.edge.activity(nw, e = e)[[1]]))
  edge_lab <- function(x) {
    el <- as.matrix(x, matrix.type = "edgelist")
    if (nrow(el) == 0) return("")
    pid <- x %v% "vertex.names"
    a <- pid[el[, 1]]; b <- pid[el[, 2]]
    if (!directed) { lo <- pmin(a, b); hi <- pmax(a, b); a <- lo; b <- hi }
    paste(sort(paste0(a, "-", b)), collapse = ",")
  }
  network.vertex.names(nw) <- 1:n
  queries <- character(0); answers <- character(0)
  for (i in 1:8) {
    t0 <- draw_time()
    if (i <= 3) {
      x <- network.extract(nw, at = t0)
      queries <- c(queries, sprintf("at %s", fmt_num(t0)))
      va <- which(is.active(nw, at = t0, v = 1:n))
    } else {
      t1 <- t0 + sample(c(0.5, 1, 2, 4), 1)
      rule <- if (i %% 2 == 0) "any" else "all"
      x <- network.extract(nw, onset = t0, terminus = t1, rule = rule)
      queries <- c(queries, sprintf("%s %s %s", rule, fmt_num(t0), fmt_num(t1)))
      va <- which(is.active(nw, onset = t0, terminus = t1, v = 1:n, rule = rule))
    }
    answers <- c(answers, sprintf("V=%s E=%s", paste(va, collapse = ","), edge_lab(x)))
  }
  # network.collapse over an interval: R drops inactive vertices, so record
  # the active edges only (DynamicNetworks.jl keeps every vertex).
  cq <- character(0); ca <- character(0)
  for (i in 1:4) {
    t0 <- draw_time(); t1 <- t0 + sample(c(1, 2, 4, 6), 1)
    rule <- if (i %% 2 == 0) "any" else "all"
    x <- network.collapse(nw, onset = t0, terminus = t1, rule = rule)
    cq <- c(cq, sprintf("%s %s %s", rule, fmt_num(t0), fmt_num(t1)))
    ca <- c(ca, if (is.null(x) || network.size(x) == 0) "" else edge_lab(x))
  }
  rec <- reconcile.edge.activity(nw, mode = "reduce.to.vertices")
  rsp <- sapply(seq_len(nrow(pairs)), function(e) fmt_spells(get.edge.activity(rec, e = e)[[1]]))

  cat(sprintf("\n[values.case_%d]\n", g))
  cat(sprintf("directed = %s\n", if (directed) "true" else "false"))
  cat(sprintf("edges = %s\n", toml_strings(paste(pairs[, 1], pairs[, 2]))))
  cat(sprintf("ops = %s\n", toml_strings(ops)))
  cat(sprintf("vertex_spells = %s\n", toml_strings(vsp)))
  cat(sprintf("edge_spells = %s\n", toml_strings(esp)))
  cat(sprintf("queries = %s\n", toml_strings(queries)))
  cat(sprintf("answers = %s\n", toml_strings(answers)))
  cat(sprintf("collapse_queries = %s\n", toml_strings(cq)))
  cat(sprintf("collapse_answers = %s\n", toml_strings(ca)))
  cat(sprintf("reconciled_edge_spells = %s\n", toml_strings(rsp)))
}
