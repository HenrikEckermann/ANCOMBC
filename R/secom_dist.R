#' @title Sparse estimation of distance correlations among microbiomes
#'
#' @description Obtain the sparse correlation matrix for distance correlations
#' between taxa.
#'
#' @details The \href{https://projecteuclid.org/journals/annals-of-statistics/volume-35/issue-6/Measuring-and-testing-dependence-by-correlation-of-distances/10.1214/009053607000000505.full}{distance correlation},
#' which is a measure of dependence between two random variables, can be used to
#' quantify any dependence, whether linear, monotonic, non-monotonic or
#' nonlinear relationships.
#'
#' @param pseqs a list of phyloseq-class objects. For one single ecosystem,
#' specify it as \code{pseqs = list(c(phyloseq1, phyloseq2))}, where
#' \code{phyloseq1} (typically in low taxonomic levels, such as OTU or species
#' level) is used to estimate biases, while \code{phyloseq2} (can be in any
#' taxonomic level) is used to compute the correlation matrix.
#' For multiple ecosystems, simply stack the phyloseq objects. For example,
#' for two ecosystems (such as gut and tongue), specify it as
#' \code{pseqs = list(gut = c(phyloseq1, phyloseq2),
#' tongue = c(phyloseq3, phyloseq4))}.
#' @param pseudo numeric. Add pseudo-counts to the data.
#' Default is 0 (no pseudo-counts).
#' @param prv_cut a numerical fraction between 0 and 1. Taxa with prevalences
#' less than \code{prv_cut} will be excluded in the analysis. Default is 0.5.
#' @param lib_cut a numerical threshold for filtering samples based on library
#' sizes. Samples with library sizes less than \code{lib_cut} will be
#' excluded in the analysis. Default is 1000.
#' @param corr_cut numeric. To prevent false positives due to taxa with
#' small variances, taxa with Pearson correlation coefficients greater than
#' \code{corr_cut} with the estimated sample-specific bias will be flagged.
#' The pairwise correlation coefficient between flagged taxa will be set to 0s.
#' Default is 0.5.
#' @param wins_quant a numeric vector of probabilities with values between
#' 0 and 1. Replace extreme values in the abundance data with less
#' extreme values. Default is \code{c(0.05, 0.95)}. For details,
#' see \code{?DescTools::Winsorize}.
#' @param R numeric. The number of replicates in calculating the p-value for
#' distance correlation. For details, see \code{?energy::dcor.test}.
#' Default is 1000.
#' @param thresh_hard Numeric. Set a hard threshold for the correlation matrix.
#' Pairwise distance correlation less than or equal to \code{thresh_hard}
#' will be set to 0. Default is 0 (No ad-hoc hard thresholding).
#' @param max_p numeric. Obtain the sparse correlation matrix by
#' p-value filtering. Pairwise correlation coefficient with p-value greater than
#' \code{max_p} will be set to 0. Default is 0.005.
#' @param n_cl numeric. The number of nodes to be forked. For details, see
#' \code{?parallel::makeCluster}. Default is 1 (no parallel computing).
#'
#' @return a \code{list} with components:
#'         \itemize{
#'         \item{ \code{s_diff_hat}, a numeric vector of estimated
#'         sample-specific biases.}
#'         \item{ \code{y_hat}, a matrix of bias-corrected abundances}
#'         \item{ \code{mat_cooccur}, a matrix of taxon-taxon co-occurrence
#'         pattern. The number in each cell represents the number of complete
#'         (nonzero) samples for the corresponding pair of taxa.}
#'         \item{ \code{dcorr}, the sample distance correlation matrix
#'         computed using the bias-corrected abundances \code{y_hat}.}
#'         \item{ \code{dcorr_p}, the p-value matrix corresponding to the sample
#'         distance correlation matrix \code{dcorr}.}
#'         \item{ \code{dcorr_fl}, the sparse correlation matrix obtained by
#'         p-value filtering based on the cutoff specified in \code{max_p}.}
#'         }
#'
#' @seealso \code{\link{secom_linear}}
#'
#' @examples
#' library(microbiome)
#' library(tidyverse)
#' data(dietswap)
#'
#' # Subset to baseline
#' pseq = subset_samples(dietswap, timepoint == 1)
#' # Genus level data
#' phyloseq1 = pseq
#' # Phylum level data
#' phyloseq2 = aggregate_taxa(pseq, level = "Phylum")
#'
#' # print(phyloseq1)
#' # print(phyloseq2)
#'
#' set.seed(123)
#' res_dist = secom_dist(pseqs = list(c(phyloseq1, phyloseq2)), pseudo = 0,
#'                       prv_cut = 0.5, lib_cut = 1000, corr_cut = 0.5,
#'                       wins_quant = c(0.05, 0.95), R = 1000,
#'                       thresh_hard = 0.3, max_p = 0.005, n_cl = 1)
#'
#' dcorr_fl = res_dist$dcorr_fl
#'
#' @author Huang Lin
#'
#' @import microbiome
#' @importFrom energy dcor dcor.test
#' @importFrom parallel makeCluster stopCluster
#' @importFrom foreach foreach %dopar%
#' @importFrom doParallel registerDoParallel
#' @importFrom doRNG %dorng%
#' @importFrom dplyr filter bind_rows left_join right_join
#' @importFrom tidyr pivot_longer
#' @importFrom tibble rownames_to_column
#' @importFrom Hmisc rcorr
#' @importFrom DescTools Winsorize
#' @importFrom magrittr %>%
#' @importFrom rlang .data
#' @importFrom Rdpack reprompt
#'
#' @export
secom_dist = function(pseqs, pseudo = 0, prv_cut = 0.5, lib_cut = 1000,
                      corr_cut = 0.5, wins_quant = c(0.05, 0.95), R = 1000,
                      thresh_hard = 0, max_p = 0.005, n_cl = 1) {
    # ===========Sampling fraction and absolute abundance estimation==============
    if (length(pseqs) == 1) {
        abn_list = abn_est(pseqs[[1]], pseudo, prv_cut, lib_cut)
        s_diff_hat = abn_list$s_diff_hat
        y_hat = abn_list$y_hat
    } else {
        if (is.null(names(pseqs))) names(pseqs) = paste0("data", seq_along(pseqs))

        # Check common samples
        samp_names = lapply(pseqs, function(x) sample_names(x[[2]]))
        samp_common = Reduce(intersect, samp_names)
        samp_txt = sprintf(paste0("The number of samples that are common across datasets: ",
                                  length(samp_common)))
        message(samp_txt)
        if (length(samp_common) < 10) {
            stop("The number of common samples is too small. Multi-dataset computation is not recommended.")
        }

        # Rename taxa
        for (i in seq_along(pseqs)) {
            taxa_names(pseqs[[i]][[1]]) = paste(names(pseqs)[i],
                                                taxa_names(pseqs[[i]][[1]]),
                                                sep = " - ")
            taxa_names(pseqs[[i]][[2]]) = paste(names(pseqs)[i],
                                                taxa_names(pseqs[[i]][[2]]),
                                                sep = " - ")
        }
        abn_list = lapply(pseqs, function(x) abn_est(x, pseudo, prv_cut, lib_cut))
        s_diff_hat = lapply(abn_list, function(x) x$s_diff_hat)
        y_hat = dplyr::bind_rows(lapply(abn_list, function(x)
            as.data.frame(x$y_hat)))
        y_hat = as.matrix(y_hat)
    }

    # ================Sparse estimation on distance correlations==================
    cl = makeCluster(n_cl)
    registerDoParallel(cl)

    res_corr = sparse_dist(mat = t(y_hat), wins_quant, R, thresh_hard, max_p)

    stopCluster(cl)

    # To prevent FP from taxa with extremely small variances
    if (length(pseqs) == 1) {
        corr_s = cor(cbind(s_diff_hat, t(y_hat)), use = "pairwise.complete.obs")[1, -1]
        fp_ind1 = replicate(nrow(y_hat), corr_s > corr_cut)
        fp_ind2 = t(replicate(nrow(y_hat), corr_s > corr_cut))
        fp_ind = (fp_ind1 * fp_ind2 == 1)
        diag(fp_ind) = FALSE
        res_corr$dcorr[fp_ind] = 0
        res_corr$dcorr_fl[fp_ind] = 0
        res_corr$dcorr_p[fp_ind] = 1
    } else {
        for (i in seq_along(pseqs)) {
            df_s = data.frame(s = s_diff_hat[[i]]) %>%
                tibble::rownames_to_column("sample_id")
            df_y = as.data.frame(t(y_hat)) %>%
                tibble::rownames_to_column("sample_id")
            df_merge = df_s %>%
                dplyr::right_join(df_y, by = "sample_id") %>%
                dplyr::select(-.data$sample_id)
            corr_s = cor(df_merge, use = "pairwise.complete.obs")[1, -1]
            fp_ind1 = replicate(nrow(y_hat), corr_s > corr_cut)
            fp_ind2 = t(replicate(nrow(y_hat), corr_s > corr_cut))
            fp_ind = (fp_ind1 * fp_ind2 == 1)
            diag(fp_ind) = FALSE
            res_corr$dcorr[fp_ind] = 0
            res_corr$dcorr_fl[fp_ind] = 0
            res_corr$dcorr_p[fp_ind] = 1
        }
    }

    # ==================================Outputs===================================
    res = c(list(s_diff_hat = s_diff_hat, y_hat = y_hat), res_corr)
    return(res)
}
