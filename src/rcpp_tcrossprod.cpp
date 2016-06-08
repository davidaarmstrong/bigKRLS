#define ARMA_NO_DEBUG

#include <RcppArmadillo.h>
// [[Rcpp::depends(RcppArmadillo, BH, bigmemory)]]

using namespace Rcpp;
using namespace arma;

#include <bigmemory/BigMatrix.h>

// [[Rcpp::plugins(cpp11)]]

template <typename T>
void xBigTCrossProd(const Mat<T>& inBigMatA, const Mat<T>& inBigMatB, Mat<T> outBigMat) {

  Mat<T> transposed = trans(inBigMatB);
  outBigMat = inBigMatA * transposed;

}

// [[Rcpp::export]]
void BigTCrossProd(SEXP pInBigMatA, SEXP pInBigMatB, SEXP pOutBigMat) {

  XPtr<BigMatrix> xpInBigMatA(pInBigMatA);
  XPtr<BigMatrix> xpInBigMatB(pInBigMatB);
  XPtr<BigMatrix> xpOutBigMat(pOutBigMat);

  xBigTCrossProd(
    arma::Mat<double>((double *)xpInBigMatA->matrix(), xpInBigMatA->nrow(), xpInBigMatA->ncol(), false),
    arma::Mat<double>((double *)xpInBigMatB->matrix(), xpInBigMatB->nrow(), xpInBigMatB->ncol(), false),
    arma::Mat<double>((double *)xpOutBigMat->matrix(), xpOutBigMat->nrow(), xpOutBigMat->ncol(), false)
  );
}
