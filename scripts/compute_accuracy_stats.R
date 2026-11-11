#!/usr/bin/env Rscript
# Dosage r^2 (overall and by reference-panel MAF bin) and non-reference
# genotype concordance, read from the per-site table script_7 builds with
# bcftools + awk (column layout: site_key, maf, then n_samples truth allele
# counts, then n_samples (imputed_gt_count, imputed_dosage) pairs; -1 marks
# a missing call). This is the one step in the pipeline that uses R instead
# of awk: accumulating a Pearson correlation by hand in awk is exactly the
# kind of statistic a real stats runtime should do instead. Everything
# upstream (VCF access, GT/GP parsing into this table) stays bcftools/awk,
# since that is file-format handling, not statistics.
#
# Usage: compute_accuracy_stats.R <joined.tsv, no header> <maf_common_threshold>
# Prints key=value lines (parsed by script_7 with `source`).

args <- commandArgs(trailingOnly = TRUE)
joined_path <- args[1]
maf_common_threshold <- as.numeric(args[2])

first_line <- readLines(joined_path, n = 1)
n_cols <- length(strsplit(first_line, "\t")[[1]])
n_samples <- (n_cols - 2) / 3

# Column 1 (site_key) is dropped during the read (colClasses "NULL") since
# it was only needed for the join, not for the statistics below.
col_classes <- c("NULL", rep("numeric", n_cols - 1))
tbl <- read.table(joined_path, header = FALSE, sep = "\t", colClasses = col_classes)

maf          <- tbl[[1]]
truth_cols   <- 2:(1 + n_samples)
imp_gtc_cols <- seq(2 + n_samples, by = 2, length.out = n_samples)
imp_dos_cols <- imp_gtc_cols + 1

truth   <- as.matrix(tbl[, truth_cols])
imp_gtc <- as.matrix(tbl[, imp_gtc_cols])
imp_dos <- as.matrix(tbl[, imp_dos_cols])

truth[truth == -1]     <- NA
imp_gtc[imp_gtc == -1] <- NA
imp_dos[imp_dos == -1] <- NA

maf_bin <- cut(maf, breaks = c(-Inf, 0.01, maf_common_threshold, Inf),
               labels = c("rare", "low", "common"), right = FALSE)

dosage_r2 <- function(rows) {
    x <- truth[rows, , drop = FALSE]
    y <- imp_dos[rows, , drop = FALSE]
    keep <- !is.na(x) & !is.na(y)
    if (sum(keep) < 2) return(NA_real_)
    cor(x[keep], y[keep]) ^ 2
}

nonref_concordance <- function(rows) {
    x <- truth[rows, , drop = FALSE]
    g <- imp_gtc[rows, , drop = FALSE]
    nonref <- !is.na(x) & x != 0
    if (sum(nonref) == 0) return(NA_real_)
    sum(nonref & !is.na(g) & g == x) / sum(nonref)
}

all_rows <- rep(TRUE, nrow(tbl))

cat(sprintf("overall_r2=%.6f\n",         dosage_r2(all_rows)))
cat(sprintf("rare_r2=%.6f\n",            dosage_r2(maf_bin == "rare")))
cat(sprintf("low_r2=%.6f\n",             dosage_r2(maf_bin == "low")))
cat(sprintf("common_r2=%.6f\n",          dosage_r2(maf_bin == "common")))
cat(sprintf("nonref_concordance=%.6f\n", nonref_concordance(all_rows)))
cat(sprintf("n_genotype_pairs=%d\n",     sum(!is.na(truth) & !is.na(imp_dos))))
cat(sprintf("n_nonref_truth_calls=%d\n", sum(!is.na(truth) & truth != 0)))
