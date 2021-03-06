#' Kernel Regularized Least Squares with Big Matrices
#' 
#' @param y A vector of observations on the dependent variable; missing values not allowed. May be base R matrix or library(bigmemory) big.matrix.
#' @param X A matrix of observations of the independent variables; factors, missing values, and constant vectors not allowed. May be base R matrix or library(bigmemory) big.matrix.
#' @param sigma Bandwidth parameter, shorthand for sigma squared. Default: sigma <- ncol(X). Since x variables are standardized, facilitates interprepation of the Gaussian kernel, exp(-dist(X)^2/sigma) a.k.a the similarity score. Of course, if dist between observation i and j is 0, there similarity is 1 since exp(0) = 1. Suppose i and j differ by one standard deviation on each dimension. Then the similarity is exp(-ncol(X)/sigma) = exp(-1) = 0.368.  
#' @param derivative Logical: Estimate derivatives (as opposed to just coefficients)? Recommended for interpretability.
#' @param which.derivatives Optional. For which columns of X should marginal effects be estimated ("variables of interest"). If derivative=TRUE and which.derivative=NULL, all will marginal effects estimated (default settings). Example: out = bigKRLS(..., which.derivatives = c(1, 3, 5))
#' @param vcov.est Logical: Estimate variance covariance matrix? Required to obtain derivatives and standard errors on predictions (default = TRUE).
#' @param lambda Regularization parameter. Default: estimated based (in part) on the eigenvalues of the kernel via Golden Search with convergence parameter "tolerance." Must be positive, real number. 
#' @param L Lower bound of Golden Search for lambda. 
#' @param U Upper bound of Golden Search for lambda.
#' @param tol tolerance parameter for Golden Search for lambda. Default: N / 1000.
#' @param noisy Logical: Display progress to console (intermediate output, time stamps, etc.)? (Recommended particularly for SSH users, who should also use X11 forwarding to see Rcpp progress display.)
#' @param model_subfolder_name If not null, will save estimates to this subfolder of your current working directory. Alternatively, use save.bigKRLS() on the outputted object.
#' @param overwrite.existing Logical: overwrite contents in folder 'model_subfolder_name'? If FALSE, appends lowest possible number to model_subfolder_name name (e.g., ../myresults3/). 
#' @return bigKRLS Object containing slope and uncertainty estimates; summary and predict defined for class bigKRLS.
#' @examples
#'N <- 500  # proceed with caution above N = 10,000 for system with 8 gigs made avaiable to R
#'k <- 4
#'X <- matrix(rnorm(N*k), ncol=k)
#'X <- cbind(X, sample(0:1, replace = TRUE, size = nrow(X)))
#'b <- runif(ncol(X))
#'y <- X %*% b + rnorm(nrow(X))
#' out <- bigKRLS(X = X, y = y)
#' @useDynLib bigKRLS
#' @importFrom Rcpp evalCpp
#' @importFrom stats pt quantile sd var
#' @importFrom utils timestamp
#' @import bigalgebra biganalytics bigmemory shiny
#' @export
bigKRLS <- function (y = NULL, X = NULL, sigma = NULL, derivative = TRUE, which.derivatives = NULL,
                     vcov.est = TRUE, 
                     lambda = NULL, L = NULL, U = NULL, tol = NULL, noisy = TRUE,
                     model_subfolder_name=NULL, overwrite.existing=F)
{
  
  if(.Platform$GUI == "RStudio" & .Platform$OS.type == "windows"){
    stop("Windows RStudio not supported due to apparent conflict between its compiler and the dependencies of this package.\n\nWindows users should estimate with R GUI but may analyze results in RStudio by saving and then calling load.bigKRLS().")
  }
  
  if(noisy){cat("starting KRLS... \n\nvalidating inputs, prepping data, etc... \n")}
  
  if(!is.null(model_subfolder_name)){
    stopifnot(is.character(model_subfolder_name))
    
    if(!overwrite.existing & (model_subfolder_name %in% dir())){
      i <- 1
      tmp.name <- paste(model_subfolder_name, i, sep="")
      while(tmp.name %in% dir()){
        tmp.name <- paste(model_subfolder_name, i, sep="")
        i <- i + 1
      }
      if(model_subfolder_name %in% dir()){
        warning(cat("\na subfolder named",model_subfolder_name, "exists in your current working directory.\nYour output will be saved to", tmp.name, "instead.\nTo disable this safeguard, set bigKRLS(..., overwrite.existing=T) next time.\n"))
      }
      model_subfolder_name <- tmp.name
    }
    
    dir.create(model_subfolder_name)
    wd.original <- getwd()
    setwd(paste(c(wd.original, .Platform$file.sep, model_subfolder_name), collapse=""))
    cat("\nmodel estimates will be saved to:\n\n", getwd(), "\n\n")
    
  }
  
  # suppressing warnings from bigmatrix
  oldw <- getOption("warn")
  options(warn = -1)
  options(bigmemory.allow.dimnames=TRUE)
  
  return.big.rectangles <- is.big.matrix(X)
  return.big.squares <- is.big.matrix(X) | nrow(X) > 2500
  
  if(noisy){
    if(return.big.rectangles){
      cat('X inputted as big.matrix object so X and derivatives will be returned as bigmatrix objects.')
    }else{
      cat('X inputted as base R matrix so X and derivatives will be returned as base R matrices.\n')
    }
    if(return.big.squares){
      cat('input given as a bigmatrix object or N > 2,500.\nKernel and other N x N matrices will be returned as bigmatrices.\n')
    }else{
      cat('input given as a base R matrix object and N < 2,500.\nThe outputted object will consist entirely of base R objects.\n')
    }
  }
  if((return.big.rectangles | return.big.squares) & is.null(model_subfolder_name)){
    cat("\nWARNING: The outputted object will contain bigmemory objects.\nTo avoid crashing R, use save.bigKRLS() on the outputted object, not save().\nAlternatively, stop and re-estimate with bigKRLS(..., model.subfolder.name=\"myoutput\").\n\n")
  }

  X <- to.big.matrix(X)
  y <- to.big.matrix(y, d=1)
  
  if(is.null(colnames(X))){
    colnames(X) <- paste("x", 1:ncol(X), sep="")
  }
  colnames(X)[which(apply(as.matrix(colnames(X)), 1, nchar) == 0)] <- paste("x", which(apply(as.matrix(colnames(X)), 1, nchar) == 0), sep="")
  miss.ind <- colna(X)
  if (sum(miss.ind) > 0) { 
    stop(paste("the following columns in X contain missing data, which must be removed:", 
               paste((1:length(miss.ind))[miss.ind > 0], collapse = ', '), collapse=''))
  }
  n <- nrow(X)
  d <- ncol(X)
  
  X.init <- deepcopy(X)
  X.init.sd <- colsd(X)
  
  if(!is.null(which.derivatives)){
    if(!derivative){
      stop("which.derivative requires derivative = TRUE\n\nDerivative is a logical indicating whether derivatives should be estimated (as opposed to just coefficients); which.derivatives is a vector indicating which one (with NULL meaning all).")
    }
    stopifnot(sum(which.derivatives %in% 1:d) == length(which.derivatives))
    if(noisy){
      cat("\nmarginal effects will be calculated for the following x variables:\n")
      cat(which.derivatives, sep=", ")
    }
  }
  
  if (min(X.init.sd) == 0) {
    stop(paste("the following columns in X are constant and must be removed:",
               which(X.init.sd == 0)))
  }
  
  if (n != nrow(y)) { stop("nrow(X) not equal to number of elements in y.")}
  if (colna(y) > 0) { stop("y contains missing data.") }
  if (colsd(y) == 0) { stop("y is a constant.") }
  
  if(!is.null(lambda)){
    stopifnot(is.vector(lambda), length(lambda) == 1, is.numeric(lambda), lambda > 0)
    if(noisy){cat("Using user-inputted value of lambda:", lambda, "\n")}
  }
  
  if(!is.null(sigma)){stopifnot(is.vector(sigma), length(sigma) == 1, is.numeric(sigma), sigma > 0)}
  sigma <- ifelse(is.null(sigma), d, sigma)
  
  if (is.null(tol)) { # tolerance parameter for lambda search
    tol <- n/1000
    if(noisy){cat("\nUsing default tolerance parameter, n/1000 =", tol, "\n")}
  } else {
    stopifnot(is.vector(tol), length(tol) == 1, is.numeric(tol), tol > 0)
    if(noisy){cat("\nUsing user-inputted tolerance parameter:", tol, "\n")}
  }
  
  # removing eigentruncation option for now - re-add at a later date
  eigtrunc <- NULL
  #if (!is.null(eigtrunc) && (!is.numeric(eigtrunc) | eigtrunc > n | eigtrunc < 0)) {
  #  stop("eigtrunc, if used, must be a number between 0 and N indicating the number of eigenvalues to be used.")
  #}
  
  stopifnot(is.logical(derivative), is.logical(vcov.est))
  if (derivative & !vcov.est) { stop("vcov.est is needed to get derivatives (derivative==TRUE requires vcov.est=TRUE)")}
  
  x.is.binary <- apply(X, 2, function(x){length(unique(x))}) == 2 
  if(noisy & sum(x.is.binary) > 0){
    cat(paste("\nFirst differences will be computed for the following binary variables: ", 
              toString(colnames(X)[x.is.binary], sep=', '), sep=""))
  }
  
  y.init <- deepcopy(y)
  y.init.sd <- colsd(y.init)
  y.init.mean <- colmean(y.init)
  
  for(i in 1:ncol(X)){
    X[,i] <- (X[,i] - mean(X[,i]))/sd(X[,i])
  }
  y[,1] <- (y[,1] - mean(y[,1]))/sd(y[,1])
  
  if(noisy){cat("\ndata successfully cleaned...\n\nstep 1/5: getting Kernel...\n"); timestamp()}
  
  K <- NULL  # K is the kernel
  K <- bGaussKernel(X, sigma)
  
  if(noisy){cat("\nstep 2/5: getting Eigenvectors and values...\n"); timestamp()}
  
  Eigenobject <- bEigen(K, eigtrunc) 
  
  if (is.null(lambda)) {
    if(noisy){cat("\nstep 3/5: getting regularization parameter Lambda which minimizes Leave-One-Out-Error Loss via Golden Search...\n"); timestamp()}
    lambda <- bLambdaSearch(L = L, U = U, y = y, Eigenobject = Eigenobject, eigtrunc = eigtrunc, noisy = noisy)
  }else{
    if(noisy){cat("\nSkipping step 3/5, proceeding with user-inputted lambda...")}
  }
  
  if(noisy){cat("\nstep 4/5: getting coefficients & related estimates...\n"); timestamp()}
  
  out <- bSolveForc(y = y, Eigenobject = Eigenobject, lambda = lambda, eigtrunc = eigtrunc)
  
  # bSolveForc obtains the vector of coefficients (weights) 
  # that assign importance to the similarity scores (found in K)
  if(noisy){cat("\n\tstep 4.1: getting fitted values...\n"); timestamp()}
  yfitted <- K %*% matrix(out$coeffs, ncol=1)
  
  if (vcov.est == TRUE) {
    sigmasq <- (1/n) * bCrossProd(y - yfitted)[1,1]
    if(noisy){cat("\n\tin standardized units, sigmasq =", round(sigmasq, 5), "\n")}
    if (is.null(eigtrunc)) {  # default
      if(noisy){cat("\n\tstep 4.2: getting variance covariance of the coefficients\n\n"); timestamp()}
      m <- bMultDiag(Eigenobject$vectors, 
                     sigmasq * (Eigenobject$values + lambda)^-2)
      if(noisy){cat("... [continuing] ...\n\n"); timestamp()}
      vcovmatc <- bTCrossProd(m, Eigenobject$vectors)
      
    }else{
      
      lastkeeper = max(which(Eigenobject$values >= eigtrunc * Eigenobject$values[1]))
      if(noisy){cat("\n\tstep 4.2: getting variance covariance of the coefficients\n"); timestamp()}
      m <- bMultDiag(sub.big.matrix(Eigenobject$vectors, 
                                    firstCol=1, 
                                    lastCol=lastkeeper), 
                     sigmasq * (Eigenobject$values[1:lastkeeper] + lambda)^-2)
      if(noisy){cat("\t... [continuing vcovmatc]...\n"); timestamp()}
      vcovmatc <- bTCrossProd(m, sub.big.matrix(Eigenobject$vectors, 
                                                firstCol=1, 
                                                lastCol=lastkeeper))
    }
    if(noisy){"\tfound vcovmatc\n"}
    remove(Eigenobject)
    remove(m)
    gc()
    if(noisy){"\n\tstep 4.3: estimating variance covariance of the fitted values\n"}
    vcovmatyhat <- bCrossProd(K, vcovmatc %*% K)
    if(!is.null(model_subfolder_name) & return.big.squares){
      vcovmatyhat <- (y.init.sd^2) * vcovmatyhat
      cat("\nsaving vcovmatyhat to", getwd())
      write.big.matrix(x = vcovmatyhat, filename = "vcovmatyhat.txt")
      remove(vcovmatyhat)
      cat("\nvcovmatyhat successfully saved to disk (and removed from memory for speed).\n")
    }
    
  }else {
    vcov.est.c <- NULL
    vcov.est.fitted <- NULL
  }
  
  if (derivative == TRUE) {
    
    if(noisy){cat("\nstep 5/5: estimating marginal effects...\n\n");timestamp(); cat("\n\n")} 
    
    if(is.null(which.derivatives)){
      deriv_out <- bDerivatives(X, sigma, K, out$coeffs, vcovmatc, X.init.sd)
    }else{
      Xsubset <- deepcopy(X, cols = which.derivatives)
      deriv_out <- bDerivatives(Xsubset, sigma, K, out$coeffs, vcovmatc, X.init.sd)
    }
    
    
    if(noisy){
      cat("\n\n")
      timestamp()
      cat("\nfinished major calculations :)\n\nprepping bigKRLS output object...\n")
    }
    
    derivmat <- deriv_out$derivatives
    varavgderivmat <- deriv_out$varavgderiv
    remove(deriv_out)
    
    derivmat <- y.init.sd * derivmat
    for(i in 1:ncol(derivmat)){
      derivmat[,i] <- derivmat[,i]/X.init.sd[i]
    }
    
    attr(derivmat, "scaled:scale") <- NULL
    avgderiv <- matrix(colmean(derivmat), nrow=1)
    attr(avgderiv, "scaled:scale") <- NULL
    
    if(is.null(which.derivatives)){
      varavgderivmat <- matrix((y.init.sd/X.init.sd)^2 * as.matrix(varavgderivmat), nrow=1)
    }else{
      varavgderivmat <- matrix((y.init.sd/X.init.sd[which.derivatives])^2 * as.matrix(varavgderivmat), nrow=1)
    }
    
    attr(varavgderivmat, "scaled:scale") <- NULL
  }
  if(noisy & derivative==F){
    cat("\n\n")
    timestamp()
    cat("\nfinished major calculations :)\n\nprepping bigKRLS output object...\n")
  }
  
  # w will become bigKRLS object
  
  w <- list(coeffs = out$coeffs, 
            y = y.init[], sigma = sigma, lambda = lambda, 
            binaryindicator = x.is.binary,
            which.derivatives = which.derivatives)
  
  w[["yfitted"]] <- yfitted <- as.matrix(yfitted) * y.init.sd + y.init.mean
  w[["R2"]] <- 1 - (var(y.init - yfitted)/(y.init.sd^2))
  w[["Looe"]] <- out$Le * y.init.sd
  
  if(return.big.squares){ # returning base R matrices when sensible...
    w[["K"]] <- K
  }else{
    w[["K"]] <- K[]
  }
  if(return.big.rectangles){
    w[["X"]] <- X.init
  }else{
    w[["X"]] <- X.init[]
  }
  
  
  if (vcov.est) {
    
    vcovmatc <- (y.init.sd^2) * vcovmatc
    
    if(return.big.squares){
      
      w[["vcov.est.c"]] <- vcovmatc
      
      if(is.null(model_subfolder_name)){
        vcovmatyhat <- (y.init.sd^2) * vcovmatyhat
        w[["vcov.est.fitted"]] <- vcovmatyhat
      } # vcovmatyhat already saved otherwise
        
    }else{
      w[["vcov.est.c"]] <- vcovmatc[]
      w[["vcov.est.fitted"]] <- vcovmatyhat[]
    }
  }
  
  w[["derivative.call"]] <- derivative

  if(derivative){
    # Pseudo R2 using only Average Marginal Effects
    if(is.null(which.derivatives)){
      w[["R2AME"]] <- cor(y.init[,], (X %*% matrix(avgderiv, ncol=1))[,])^2
    }else{
      w[["R2AME"]] <- cor(y.init[,], (X[,which.derivatives] %*% matrix(avgderiv, ncol=1))[,])^2
    }
    w[["avgderivatives"]] <- avgderiv
    w[["var.avgderivatives"]] = varavgderivmat
    
    if(return.big.rectangles){
      w[["derivatives"]] <- derivmat
    }else{
      w[["derivatives"]] <- derivmat[]
    }
    if(is.null(which.derivatives)){
      colnames(w$derivatives) <- colnames(w$avgderivatives) <- colnames(X.init)
    }else{
      colnames(w$derivatives) <- colnames(w$avgderivatives) <- colnames(X.init)[which.derivatives]
    }
    
    if (noisy) {
      cat("\n\nAverage Marginal Effects: \n")
      print(round(w$avgderivatives, 3))
      cat("\n Percentiles of Local Derivatives: \n")
      print(round(apply(as.matrix(w$derivatives), 2, 
                        quantile, probs = c(0.25, 0.5, 0.75)),3))
    }
  }
  class(w) <- "bigKRLS" 
  
  if(!is.null(model_subfolder_name)){
    
    cat("\nsaving ouput to", getwd(), "\n")
    w[["path"]] <- getwd()
    w[["has.big.matrices"]] <- return.big.squares | return.big.rectangles
      
    for(i in which(unlist(lapply(w, is.big.matrix)))){
      cat("\twriting", paste(c(names(w)[i], ".txt"), collapse = ""), "...\n")
      write.big.matrix(x = w[[i]], col.names = !is.null(colnames(w[[i]])),
                       filename = paste(c(names(w)[i], ".txt"), collapse = ""))
    }
    
    Nbm <- sum(unlist(lapply(w, is.big.matrix))) + return.big.squares
    cat("\n\n", Nbm, "matrices saved as big matrices.\n") 
    if(Nbm == 0){
      cat(" (base R save() may be used safely in this case too).\n")
    }else{
      cat("\nto reload, use syntax like:\n\nload.bigKRLS(\"", w$path, "\")\n or\n",
          "load.bigKRLS(\"", w$path, "\", newname=\"my_estimates\")\n", sep="")}
    if(Nbm > 0){
      bigKRLS_out <- w[-which(unlist(lapply(w, is.big.matrix)))]
    }else{
      bigKRLS_out <- w
    }
    stopifnot(sum(unlist(lapply(bigKRLS_out, is.big.matrix))) == 0)
    save(bigKRLS_out, file="estimates.rdata")
    cat("\nbase R elements of the output saved to estimates.rdata.\n")
    cat("Total file size approximately", round(sum(file.info(list.files())$size)/1024^2), "megabytes.\n\n")
    setwd(wd.original) 
  }
  
  cat("\nAll done. You may wish to use summary() for more detail, predict() for out-of-sample forecasts, or shiny.bigKRLS() to interact with results. Type vignette(\"bigKRLS_basics\") for sample syntax. Use save.bigKRLS() to store results and load.bigKRLS() to re-open them.\n\n")
  
  return(w)
  
  options(warn = oldw)
}  

#' @export
bLambdaSearch <- function (L = NULL, U = NULL, y = NULL, Eigenobject = NULL, tol = NULL, 
                           noisy = FALSE, eigtrunc = NULL){
  n <- nrow(y)
  if (is.null(tol)) {
    tol <- 10^-3 * n # tolerance parameter
  } else {
    stopifnot(is.vector(tol), length(tol) == 1, is.numeric(tol), tol > 0)
  }
  if (is.null(U)) {
    U <- n
    while (sum(Eigenobject$values/(Eigenobject$values + U)) < 1) {
      U <- U - 1
    }
  } else {
    stopifnot(is.vector(U), length(U) == 1, is.numeric(U), U > 0)
  }
  if (is.null(L)) {
    q <- which.min(abs((Eigenobject$values - max(Eigenobject$values)/1000)))
    
    L = .Machine$double.eps
    # smallest double such that 1 + x != 1. Normally 2.220446e-16.
    
    while (sum(Eigenobject$values/(Eigenobject$values + L)) > q) {
      L <- L + 0.05 
    } 
  } else {
    stopifnot(is.vector(L), length(L) == 1, is.numeric(L), L >= 0)
  }
  X1 <- L + (0.381966) * (U - L) 
  X2 <- U - (0.381966) * (U - L)
  
  # bLooLoss is big Leave One Out Error Loss
  
  if(noisy) cat("\ngetting S1... \n")
  S1 <- bLooLoss(lambda = X1, y = y, Eigenobject = Eigenobject, 
                 eigtrunc = eigtrunc)
  if(noisy) cat("\ngetting S2... \n")
  S2 <- bLooLoss(lambda = X2, y = y, Eigenobject = Eigenobject, 
                 eigtrunc = eigtrunc)
  f3 <- function(x){format(round(x, digits=3), nsmall=3)}
  if (noisy) {
    cat("\nstarting values of Golden Search:") 
    cat("\nL:", f3(L), 
        "X1:", f3(X1), "X2:", f3(X2), 
        "U:", f3(U), "S1:", f3(S1), "S2:", f3(S2), 
        "\n")
  }
  while (abs(S1 - S2) > tol) {
    if (S1 < S2) {
      U <- X2
      X2 <- X1
      X1 <- L + (0.381966) * (U - L)
      S2 <- S1
      S1 <- bLooLoss(lambda = X1, y = y, Eigenobject = Eigenobject, 
                     eigtrunc = eigtrunc)
    }
    else {
      L <- X1
      X1 <- X2
      X2 <- U - (0.381966) * (U - L)
      S1 <- S2
      S2 <- bLooLoss(lambda = X2, y = y, Eigenobject = Eigenobject, 
                     eigtrunc = eigtrunc)
    }
    if (noisy) {
      cat("\nL:", f3(L), 
          "X1:", f3(X1), "X2:", f3(X2), 
          "U:", f3(U), "S1:", f3(S1), "S2:", f3(S2), 
          "\n")
    }
  }
  out <- ifelse(S1 < S2, X1, X2)
  
  if (noisy) {cat("\nLambda:", round(out, 5), "\n")}
  
  return(invisible(out))
}

#' @export
bSolveForc <- function (y = NULL, Eigenobject = NULL, lambda = NULL, eigtrunc=NULL) {
  out <- BigSolveForc(Eigenobject$vectors@address, Eigenobject$values, y[], lambda)
  
  return(list(Le = out[[1]], coeffs = out[[2]]))
}

#' @export
bLooLoss <- function (y = NULL, Eigenobject = NULL, lambda = NULL, eigtrunc = NULL) 
{
  return(bSolveForc(y = y, Eigenobject = Eigenobject, lambda = lambda, 
                    eigtrunc = eigtrunc)$Le)
} # not sure that there's any point to this function
# could just make "bLooLoss" mode a parameter of bSolveForc

#' @export
predict.bigKRLS <- function (object, newdata, se.fit = FALSE, ...) 
{
  if (class(object) != "bigKRLS") {
    warning("Object not of class 'bigKRLS'")
    UseMethod("predict")
    return(invisible(NULL))
  }
  if(se.fit == TRUE) {
    if (is.null(object$vcov.est.c)) {
      stop("recompute bigKRLS object with bigKRLS(,vcov.est=TRUE) to compute standard errors")
    }
  }
  
  # convert everything to a bigmatrix for internal usage
  object$X <- to.big.matrix(object$X)
  object$K <- to.big.matrix(object$K)
  object$derivatives <- to.big.matrix(object$derivatives)
  object$vcov.est.c <- to.big.matrix(object$vcov.est.c)
  if(!is.null(object$vcov.est.fitted)){
    object$vcov.est.fitted <- to.big.matrix(object$vcov.est.fitted)  
  }else{
    cat("vcov.est.fitted not found in bigKRLS object, attempting to load from object's path,\n ",object$path)
    object$vcov.est.fitted <- read.big.matrix(filename = paste(object$path, "vcovmatyhat.txt", sep=.Platform$file.sep),
                                              type='double')
    cat("\nvcovmatyhat loaded successfully\n")
  }
  
  
  # set bigmatrix flag for input data for later
  if(!is.big.matrix(newdata)){
    bigmatrix.in <- FALSE
  } else{
    bigmatrix.in <- TRUE
  }
  
  newdata <- to.big.matrix(newdata)
  
  if (ncol(object$X) != ncol(newdata)) {
    stop("ncol(newdata) differs from ncol(X) from fitted bigKRLS object")
  }
  Xmeans <- colmean(object$X)
  Xsd <- colsd(object$X)
  
  for(i in 1:ncol(object$X)){
    object$X[,i] <- (object$X[,i] - Xmeans[i])/Xsd[i]
  }  
  
  newdata.init <- newdata
  
  for(i in 1:ncol(newdata)){
    newdata[,i] <- (newdata[,i] - Xmeans[i])/Xsd[i]
  }
  
  newdataK <- bTempKernel(newdata, object$X, object$sigma)
  
  # convert to regular matrix
  yfitted <- (newdataK %*% as.matrix(object$coeffs, ncol=1))[]
  
  if (se.fit) {
    vcov.est.c.raw <- object$vcov.est.c * (1/var(object$y))
    vcov.est.fitted <- bTCrossProd(newdataK %*% vcov.est.c.raw, newdataK)
    vcov.est.fit <- var(object$y) * vcov.est.fitted
    se.fit <- matrix(sqrt(diag(vcov.est.fit[])), ncol = 1)
  }
  else {
    vcov.est.fit <- se.fit <- NULL
  }
  
  yfitted <- (yfitted * sd(object$y) + mean(object$y))
  
  
  
  if(!bigmatrix.in){
    newdata <- newdata[]
    vcov.est.fit <- vcov.est.fit[]
    newdataK <- newdataK[]
  }
  
  return(list(fit = yfitted, se.fit = se.fit, vcov.est.fit = vcov.est.fit, 
              newdata = newdata, newdataK = newdataK))
}

#' @export
summary.bigKRLS <- function (object, probs = c(0.05, 0.25, 0.5, 0.75, 0.95), digits=4,...) 
{
  if (class(object) != "bigKRLS") {
    warning("Object not of class 'bigKRLS'")
    UseMethod("summary")
    return(invisible(NULL))
  }
  cat("\n\nMODEL SUMMARY:\n\n")
  cat("R2:", round(object$R2, digits), "\n")
  
  if (is.null(object$derivatives)) {
    cat("\nrecompute with bigKRLS(..., derivative = TRUE) for estimates of marginal effects\n")
    return(invisible(NULL))
  }
  
  n <- nrow(object$X)
  d <- ncol(object$X)
  
  cat("R2AME**:", round(object$R2AME, digits), "\n\n")
  if(is.null(object$which.derivatives)){
    object$which.derivatives <- 1:d
  }
  
  est <- object$avgderivatives
  se <- sqrt(object$var.avgderivatives)
  tval <- est/se
  pval <- 2 * pt(abs(tval), n - d, lower.tail = FALSE)
  AME <- t(rbind(est, se, tval, pval))
  colnames(AME) <- c("Estimate", "Std. Error", "t value", "Pr(>|t|)")
  rownames(AME) <- colnames(object$X)[object$which.derivatives]
  if (sum(object$binaryindicator[object$which.derivatives]) > 0) {
    tmp <- rownames(AME)[object$binaryindicator[object$which.derivatives]]
    rownames(AME)[object$binaryindicator[object$which.derivatives]] <- paste(tmp, "*", sep="")
  }
  cat("Average Marginal Effects:\n\n")
  print(round(AME, digits))
  
  cat("\n\nPercentiles of Local Derivatives:\n\n")
  
  qderiv <- t(apply(object$derivatives, 2, quantile, probs = probs))
  rownames(qderiv) <- rownames(AME)
  print(round(qderiv, digits))
  
  if (sum(object$binaryindicator) > 0) {
    cat("\n(*) Reported average and percentiles of dy/dx is for discrete change of the dummy variable from min to max (usually 0 to 1)).\n\n")
  }
  cat("\n(**) Pseudo-R^2 computed using only the Average Marginal Effects. If only a subset of marginal effects were estimated, Pseudo-R^2 calculated with that subset.\n\n")
  cat("\nYou may also wish to use predict() for out-of-sample forecasts or shiny.bigKRLS() to interact with results. Type vignette(\"bigKRLS_basics\") for sample syntax. Use save.bigKRLS() to store results and load.bigKRLS() to re-open them.\n\n")
  ans <- list(marginalfx_summary = AME, 
              marginalfx_percentiles = qderiv)
  class(ans) <- "summary.bigKRLS"
  return(invisible(ans))
    
}


#' @export
save.bigKRLS <- function (object, model_subfolder_name, overwrite.existing=F) 
{
  if (class(object) != "bigKRLS") {
    warning("Object not of class 'bigKRLS'")
    UseMethod("save")
    return(invisible(NULL))
  }
  stopifnot(is.character(model_subfolder_name))
  
  if(!overwrite.existing & (model_subfolder_name %in% dir())){
    i <- 1
    tmp.name <- paste(model_subfolder_name, i, sep="")
    while(tmp.name %in% dir()){
      tmp.name <- paste(model_subfolder_name, i, sep="")
      i <- i + 1
    }
    if(model_subfolder_name %in% dir()){
      warning(cat("A subfolder named",model_subfolder_name, "exists in your current working directory. Your output will be saved to", tmp.name, "instead. To turn off this safeguard, set save.bigKRLS(..., overwrite.existing=T) next time.\n\n"))
    }
    model_subfolder_name <- tmp.name
  }
  
  dir.create(model_subfolder_name)
  wd.original <- getwd()
  setwd(paste(c(wd.original, .Platform$file.sep, model_subfolder_name), collapse=""))
  cat("Saving model estimates to:\n\n", getwd(), "\n\n")
  object[["path"]] <- getwd()
  
  for(i in which(unlist(lapply(object, is.big.matrix)))){
    cat("\twriting", paste(c(names(object)[i], ".txt"), collapse = ""), "...\n")
    write.big.matrix(x = object[[i]], col.names = !is.null(colnames(object[[i]])),
                     filename = paste(c(names(object)[i], ".txt"), collapse = ""))
  }
  
  Nbm <- sum(unlist(lapply(object, is.big.matrix)))
  cat("\n", Nbm, " matrices saved as big matrices", 
      ifelse(Nbm == 0, " (base R save() may be used safely in this case too).\n",
             ", use load.bigKRLS() on the entire directory to reconstruct the outputted object in R.\n"), sep="")
  if(Nbm > 0){
    bigKRLS_out <- object[-which(unlist(lapply(object, is.big.matrix)))]
  }else{
    bigKRLS_out <- object
  }
  remove(object)
  stopifnot(sum(unlist(lapply(bigKRLS_out, is.big.matrix))) == 0)
  save(bigKRLS_out, file="estimates.rdata")
  cat("Smaller, base R elements of the outputted object saved in estimates.rdata.\n")
  cat("Total file size approximately", round(sum(file.info(list.files())$size)/1024^2), "megabytes.")
  setwd(wd.original) 
}

#' @export
load.bigKRLS <- function(path, newname = NULL){
  
  stopifnot(is.null(newname) | is.character(newname))
  
  wd.original <- getwd()
  setwd(path)
  files <- dir()
  if(!("estimates.rdata" %in% files)){
    stop("estimates.rdata not found. Check the path to the output folder.\n\nNote: for any files saved manually, note that load.bigKRLS() anticipates the convention used by save.bigKRLS: estimates.rdata stores the base R objects in a list called bigKRLS_out, big matrices stored as text files named like they are in bigKRLS objects (object$K becomes K.txt, etc.).\n\n")
  }
  name = load("estimates.rdata")
  
  if(bigKRLS_out$has.big.matrices){ 
    cat("Loading big matrices from", getwd(), "\n\n")
    if(!("K" %in% names(bigKRLS_out))){
      if(!("K.txt" %in% files)){
        cat("WARNING: Kernel not found in .rdata or in big matrix file K.txt\n\n")
      }else{
        cat("\tReading kernel from K.txt...\n")
        bigKRLS_out$K <- read.big.matrix("K.txt", type = "double")
      }
    }
    if(!("X" %in% names(bigKRLS_out))){
      if(!("X.txt" %in% files)){
        cat("WARNING: X matrix not found in .rdata or in big matrix file X.txt\n\n")
      }else{
        cat("\tReading X matrix from X.txt...\n")
        bigKRLS_out$X <- read.big.matrix("X.txt", type = "double", header=T)
      }
    }
    if(!("derivatives" %in% names(bigKRLS_out))){
      if(!("derivatives.txt" %in% files)){
        cat("WARNING: derivatives matrix not found in .rdata or in big matrix file derivatives.txt\n\n")
      }else{
        cat("\tReading derivatives matrix from derivatives.txt...\n")
        bigKRLS_out$derivatives <- read.big.matrix("derivatives.txt", type = "double", header=T)
      }
    }
    if(!("vcov.est.c" %in% names(bigKRLS_out))){
      if(!("vcov.est.c.txt" %in% files)){
        cat("WARNING: variance covariance matrix of the coefficients not found in .rdata or in big matrix file vcov.est.c.txt (necessary to compute standard errors of predictions)\n\n")
      }else{
        cat("\tReading variance covariance matrix of the coefficients from vcov.est.c.txt...\n")
        bigKRLS_out$vcov.est.c <- read.big.matrix("vcov.est.c.txt", type = "double")
      }
    }
    if(!("vcov.est.fitted" %in% names(bigKRLS_out))){
      if(!("vcov.est.fitted.txt" %in% files)){
        cat("WARNING: variance covariance matrix of the fitted values not found in .rdata or in big matrix file vcov.est.fitted.txt\n\n")
      }else{
        cat("\tReading variance covariance matrix of the fitted values from vcov.est.fitted.txt...\n\n")
        bigKRLS_out$vcov.est.fitted <- read.big.matrix("vcov.est.fitted.txt", type = "double")
      }
    }
  }
  if(is.null(newname)){
    newname = name
  }
  class(bigKRLS_out) <- "bigKRLS"
  assign(newname, bigKRLS_out, envir = .GlobalEnv)
  cat("New bigKRLS object created named", newname, "with", length(bigKRLS_out), "out of 16 possible elements of the bigKRLS class.\n\nOptions for this object include: summary(), predict(), and shiny.bigKRLS().\nRun vignette(\"bigKRLS_basics\") for detail")
  setwd(wd.original)
}


#' @export
to.big.matrix <- function(obj, d=NULL){
  if(is.null(d)){
    d <- ifelse(!is.null(ncol(obj)), ncol(obj), 1)
  }
  
  if(!is.big.matrix(obj)){
    obj <- as.big.matrix(matrix(obj, ncol=d))
  }
  return(obj)
}

#' @export
shiny.bigKRLS <- function(out, export=F, main.label = NULL, plot.main.label = NULL, labs = NULL,
                          shiny.palette = c("#E41A1C", "#377EB8", "#4DAF4A", "#984EA3",
                                            "#FF7F00", "#FFFF33", "#A65628", "#F781BF", "#999999")){
  
  if(!export){cat("export set to false; set export to true to prepare files for server or other machine.")}
  if(!is.null(labs)){
    colnames(out$X) <- colnames(out$derivatives) <- names(out$avgderivatives) <- names(out$var.avgderivatives) <- labs
  }
  
  palette(shiny.palette)
  
  bigKRLS_server <- shinyServer(function(input, output, session) {
    
    selectedData <- reactive({
      return(list(cbind(out$derivatives[, input$dydxp], 
                        out$X[, c(input$xp)]), input$type))
    })
    
    output$graph <- renderPlot({
      
      if(selectedData()[[2]] == "Smooth"){
        
        L <- loess.smooth(x=selectedData()[[1]][,2], 
                          y=selectedData()[[1]][,1])
        
        plot(y=L$y, x=L$x, ylab=paste("Marginal Effect of",input$dydxp), pch = 19, bty = "n",
             main=plot.main.label, 
             xlab=paste("Observed Level of", input$xp), cex=2, cex.axis=1.5,  cex.lab=1.4,
             col = colorRampPalette(c("blue", "red"))(length(L$y))[rank(L$y)])
        
      }else{
        plot(x=(selectedData()[[1]][,2]), xlab = paste("Observed Level of", input$xp),
             y=(selectedData()[[1]][,1]), ylab = paste("Marginal Effect of",input$dydxp), 
             pch = 4, bty = "n", cex=2, cex.axis=1.5,  cex.lab=1.4,
             main=plot.main.label,
             col = colorRampPalette(c("green", "purple"))(nrow(out$X))[rank(out$coeffs^2)], 
             ylim = range(selectedData()[[1]][,1])*c(.8, 1.25), 
             xlim = range(selectedData()[[1]][,2])*c(.8, 1.25))
        
        fields::image.plot(legend.only = T, zlim=c(1/nrow(out$X), 1), 
                           legend.cex = 0.75,legend.shrink = .4,   
                           col = colorRampPalette(c("purple", "green"))(nrow(out$X)))
        text(x = 1.2*range(selectedData()[[1]][,2])[2], 
             y = .75*range(selectedData()[[1]][,1])[2], 
             "Relative Fit \nIn Full Model") 
      }
    })})
  
  bigKRLS_ui <- shinyUI(fluidPage(
    
    titlePanel(main.label),
    
    sidebarPanel(
      selectInput('dydxp', 'Local Derivatives (dy/dx)', colnames(out$derivatives)),
      selectInput('xp', 'x', colnames(out$X)), 
      selectInput('type', 'Plot Type', c("Smooth", "Scatter"))
    ),
    
    mainPanel(plotOutput('graph'))
    
  ))
  
  if(export){
    
    out <- out
    out$K <- tmp$vcov.c <- tmp$vcov.fitted <- NULL
    for(i in which(unlist(lapply(out, is.big.matrix)))){
      out[[i]] <- as.matrix(out[[i]])
    }
    
    save(out, file="shiny_out.rdata")
    
    cat("A re-formatted version of your output has been saved with file name \"shiny_out.rdata\" in your current working directory:\n", getwd(),
        "\nFor a few technical reasons, the big N * N matrices have been removed and the smaller ones converted back to base R;\nthis should make your output small enough for the free version of Shiny's server.\nTo access the Shiny app later or on a different machine, simply execute this script with the following commands:\n",
        "\nload(\"shiny_out.rdata\")\nNext, execute this script to make sure Shiny is initialized with current values. \nshiny_bigKRLS(out)")
  }else{
    shinyApp(ui = bigKRLS_ui, server = bigKRLS_server)
  }
}


##################
# Rcpp Functions #
##################

#' @export
bMultDiag <- function (X, v) {
  #rcpp_multdiag.cpp
  out <- big.matrix(nrow=nrow(X),
                    ncol=ncol(X),
                    init=0,
                    type='double')
  
  BigMultDiag(X@address, v, out@address)
  
  return(out)
}

#' @export
bEigen <- function(X, eigtrunc){
  #rcpp_eigen.cpp
  vals <- big.matrix(nrow = 1,
                     ncol = ncol(X),
                     init = 0,
                     type = 'double')
  vecs <- big.matrix(nrow = nrow(X),
                     ncol = ncol(X),
                     init=0,
                     type='double')
  if(is.null(eigtrunc)){
    eigtrunc <- ncol(X)
  }
  
  BigEigen(X@address, eigtrunc, vals@address, vecs@address)
  return(list('values' = vals[,], 'vectors' = vecs*-1))
}

#' @export
bGaussKernel <- function(X, sigma){
  #rcpp_gauss_kernel.cpp
  out <- big.matrix(nrow=nrow(X), ncol=nrow(X), init=0)
  
  BigGaussKernel(X@address, out@address, sigma)
  return(out)
}

#' @export
bTempKernel <- function(X_new, X_old, sigma){
  #rcpp_temp_kernel.cpp
  out <- big.matrix(nrow=nrow(X_new), ncol=nrow(X_old), init=0)
  
  BigTempKernel(X_new@address, X_old@address, out@address, sigma)
  return(out)
}

#' @export
bCrossProd <- function(X,Y=NULL){
  if(is.null(Y)){
    Y <- deepcopy(X)
  }
  out <- big.matrix(nrow = ncol(X),
                    ncol = ncol(Y),
                    init = 0,
                    type = 'double')
  BigCrossProd(X@address, Y@address, out@address)
  return(out)
}

#' @export
bTCrossProd <- function(X,Y=NULL){
  if(is.null(Y)){
    Y <- deepcopy(X)
  }
  out <- big.matrix(nrow = nrow(X),
                    ncol = nrow(Y),
                    init = 0,
                    type = 'double')
  BigTCrossProd(X@address, Y@address, out@address)
  return(out)
}

#' @export
bDiag <- function(X){
  # return the diagonal elements of a bigmatrix
  out <- sapply(1:nrow(X), function(i){X[i,i]})
  return(out)
}

#' @export
bDerivatives <- function(X,sigma,K,coeffs,vcovmatc, X.sd){
  
  derivatives <- big.matrix(nrow=nrow(X), ncol=ncol(X), init=-1)
  varavgderiv <- big.matrix(nrow=1, ncol=ncol(X), init=-1)
  out <- BigDerivMat(X@address, K@address, vcovmatc@address, 
                     derivatives@address, varavgderiv@address,
                     X.sd, coeffs, sigma)
  
  return(list('derivatives'=derivatives, 'varavgderiv'=varavgderiv[]))
}
