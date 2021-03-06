#' runPipeline
#' 
#' This function runs a pipeline with combinations of parameter variations on 
#' nested steps. The pipeline has to be defined as a list of functions applied 
#' consecutively on their respective outputs. See 'examples' for more details. 
#'
#' @param datasets A named vector of initial objects or paths to rds files.
#' @param alternatives The (named) list of alternative values for each 
#' parameter.
#' @param pipelineDef An object of class `PipelineDefinition`.
#' @param comb An optional matrix of indexes indicating the combination to run. 
#' Each column should correspond to an element of `alternatives`, and contain 
#' indexes relative to this element. If omitted, all combinations will be 
#' performed.
#' @param output.prefix An optional prefix for the output files.
#' @param nthreads Number of threads, defaults to the number of datasets.
#' @param saveEndResults Logical; whether to save the output of the last step.
#' @param debug Logical (default FALSE). When enabled, disables multithreading 
#' and prints extra information.
#' @param ... passed to MulticoreParam. Can for instance be used to set 
#' `makeCluster` arguments, or set `threshold="TRACE"` when debugging in a 
#' multithreaded context.
#'
#' @examples 
#' 
#' # Example of function list that will define the alternatives of the pipeline: 
#' source(system.file("extdata", "scrna_alternatives.R", package="pipeComp"))
#' scrna_seurat_defAlternatives()
#' 
#' # We can also specify the alternatives manually:
#' alternatives <- list(
#'  doubletmethod=c("none"),
#'  filt=c("filt.lenient"),
#'  norm=c("norm.seurat", "norm.seuratvst", "norm.scran"),
#'  sel=c("sel.vst"),
#'  selnb=2000,
#'  dr=c("seurat.pca"),
#'  clustmethod=c("clust.seurat"),
#'  maxdim=30,
#'  dims=c(10, 15, 20, 30),
#'  k=20,
#'  steps=4,
#'  resolution=c(0.01, 0.1, 0.2, 0.3, 0.5, 0.8, 1, 1.2, 2),
#'  min.size=50   
#'  )
#'  
#' # run the pipeline:
#' res <- runPipeline( datasets, alternatives, pipDef, nthreads=3,
#'   output.prefix="myfolder/" )
#'   
#' # Any additional functions can be used in the pipeline by adding them in the 
#' # global environment (via "scrna_alternatives.R", other R script, etc...).
#' 
#' @return A SimpleList with elapsed time and the results of the evaluation 
#' functions defined by the given `pipelineDef`.
#' 
#' The results are also stored in the output folder with: 
#' \itemize{
#' \item The clustering results for each dataset (`endOutputs.rds` files),
#' \item A SimpletList of elapsed time and evaluations for each dataset 
#' (`evaluation.rds` files),
#' \item A list of the `pipelineDef`, `alternatives`, `sessionInfo()` and function 
#' call used to produce the results (`runPipelineInfo.rds` file),
#' \item A copy of the SimpleList returned by the function (`aggregated.rds`file). 
#' }
#' 
#' @import methods BiocParallel S4Vectors
#' @export
#' @examples
#' pip <- mockPipeline()
#' datasets <- list( ds1=1:3, ds2=c(5,10,15) )
#' tmpdir1 <- paste0(tempdir(),"/")
#' res <- runPipeline(datasets, pipelineDef=pip, output.prefix=tmpdir1)
runPipeline <- function( datasets, alternatives, pipelineDef, comb=NULL, 
                         output.prefix="", nthreads=length(datasets), 
                         saveEndResults=TRUE, debug=FALSE, ...){
  mcall <- match.call()
  if(!is(pipelineDef,"PipelineDefinition")) 
    pipelineDef <- PipelineDefinition(pipelineDef)
  alternatives <- .checkPipArgs(alternatives, pipelineDef)
  pipDef <- pipelineDef@functions
  
  if(is.null(names(datasets)))
    names(datasets) <- paste0("dataset",seq_along(datasets))
  if(any(grepl(" ",names(datasets)))) 
    stop("Dataset names should not have spaces.")
  if(any(grepl("\\.",names(datasets)))) 
    warning("It is recommended not to use dots ('.') in dataset names to 
            facilitate browsing aggregated results.")
  
  # extract the arguments required by the pipeline
  args <- arguments(pipelineDef)
  
  # check that output folder exists, otherwise create it
  if(output.prefix!=""){
    x <- gsub("[^/]+$","",output.prefix)
    if(x!="" && !dir.exists(x)) dir.create(x, recursive=TRUE)
  }
  
  # prepare the combinations of parameters to use
  alt <- alternatives[unlist(args)]
  if(is.null(comb)){
    eg <- buildCombMatrix(alt, TRUE)
  }else{
    eg <- .checkCombMatrix(comb, alt)
  }
  
  ## BEGIN .runPipelineF
  .runPipelineF <- function(dsi){
    dsname <- dsi
    ds <- pipelineDef@initiation(datasets[[dsi]])
    
    if(debug) message(dsname)

    elapsed <- lapply(pipDef, FUN=function(x) list())
    elapsed.total <- list()
    
    objects <- c(list(BASE=ds), lapply(args[-length(args)],FUN=function(x)NULL))
    intermediate_return_objects <- lapply(args, FUN=function(x) list() )
    rm(ds)
    
    res <- sapply(1:nrow(eg), FUN=function(x) NULL)
    for(n in 1:nrow(eg)){
      newPar <- as.numeric(eg[n,])
      aa <- paste( mapply(an=names(alt), a=alt, i=newPar, 
                          FUN=function(an,a,i) paste0(an,"=",a[i]) )
                   ,collapse=", ")
      if(debug){
        message("
                ####################
                # Iteration ",n,"
                # ", aa)
      }
      if(n==1){
        oldPar <- rep(0,ncol(eg))
      }else{
        oldPar <- as.numeric(eg[n-1,])
      }
      # identify the first parameters that changes and the corresponding step
      chParam <- names(alt)[which(newPar!=oldPar)[1]]
      wStep <- which(sapply(args,FUN=function(x){ chParam %in% x }))
      # fetch the object from the previous step
      x <- objects[[which(names(objects)==names(args)[wStep])-1]]
      # proceed with the remaining steps of the pipeline
      for(step in names(args)[wStep:length(args)]){
        if(debug) message(step)
        # prepare the arguments
        a <- lapply(args[[step]], FUN=function(a){
          alt[[a]][newPar[which(colnames(eg)==a)]]
        })
        names(a) <- args[[step]]
        #a$x <- x
        #x <- do.call(pipDef[[step]], a)   ## unknown issue with do.call...
        fcall <- .mycall(pipDef[[step]], a)
        if(debug) message(fcall)
        st <- Sys.time()
        x <- tryCatch( eval(fcall),
                       error=function(e){
  ## error report
   if(debug) save(x, step, pipDef, fcall, newPar, 
                  file=paste0(output.prefix,"runPipeline_error_TMPdump.RData"))
   msg <- paste0("Error in dataset `", dsi, "` with parameters:\n", aa, 
                "\nin step `", step, "`, evaluating command:\n`", fcall, "`
                Error:\n", e, "\n", 
                ifelse(debug, paste0("Current variables dumped in ", 
                                     output.prefix,
                                     "runPipeline_error_TMPdump.RData"), ""))
   if(!debug || nthreads>1) print(msg)
   stop( msg )
  ## end error report
                       })

        # name the current results on the basis of the previous steps:
        ws <- 1:sum(sapply(args[1:which(names(args)==step)], length))
        ename <- .args2name(newPar[ws], alt[ws])
        # save elapsed time for this step
        elapsed[[step]][[ename]] <- as.numeric(Sys.time()-st)
        # save eventual intermediate objects (e.g. step evaluation)
        if(is.list(x) && all(c("x","intermediate_return") %in% names(x))){
          intermediate_return_objects[[step]][[ename]] <- x$intermediate_return
          x <- x$x
        }else{
          if(!is.null(pipelineDef@evaluation[[step]])){
            intermediate_return_objects[[step]][[ename]] <- 
              pipelineDef@evaluation[[step]](x)
          }
        }
        objects[[step]] <- x
      }

      # compute total time for this iteration
      elapsed.total[[n]] <- sum(sapply(names(args),FUN=function(step){
        ws <- 1:sum(sapply(args[1:which(names(args)==step)], length))
        ename <- .args2name(newPar[ws], alt[ws])
        elapsed[[step]][[ename]]
      }))
      
      # return final results
      res[[n]] <- x
    }
    
    if(debug) message("
                      Completed running all variations.")
    
    # set names as the combination of arguments
    names(res) <- apply(eg,1,alt=alt,FUN=.args2name)
    names(elapsed.total) <- names(res)
    res <- lapply(res,FUN=function(x){
      ## refactor keeping names
      xn <- names(x)
      x <- factor(as.character(x))
      names(x) <- xn
      x
    })

    if(saveEndResults)
      saveRDS(res, file=paste0(output.prefix,"res.",dsi,".endOutputs.rds"))
    
    res <- SimpleList( evaluation=intermediate_return_objects,
                       elapsed=list( stepwise=elapsed, total=elapsed.total ) )
    metadata(res)$PipelineDefinition <- pipelineDef
    
    ifile <- paste0(output.prefix,"res.",dsi,".evaluation.rds")
    saveRDS(res, file=ifile)
    return(ifile)
  }
  ## END .runPipelineF
  
  names(dsnames) <- dsnames <- names(datasets)
  if(!debug && nthreads>1 && length(datasets)>1){
    nthreads <- min(nthreads, length(datasets))
    message(paste("Running", nrow(eg), "pipeline settings on", length(datasets),
                  "datasets using",nthreads,"threads"))
    resfiles <- bplapply( dsnames, 
                          BPPARAM=MulticoreParam(nthreads, ...), 
                          FUN=.runPipelineF )
  }else{
    nthreads <- 1
    if(debug) message("Running in debug mode (single thread)")
    resfiles <- lapply( dsnames, FUN=.runPipelineF)
  }

  message("
                  Finished running on all datasets, now aggregating results...")
  
  # save pipeline and resolved functions
  pipinfo <- list( pipDef=pipelineDef,
                   alts=lapply(alt, FUN=function(x){ 
                     if(is.numeric(x)) return(x)
                     lapply(x,FUN=function(x){
                       if(is.function(x)) return(x)
                       if(exists(x) && is.function(get(x))){
                         return(get(x))
                       }else{
                         return(x)
                       }
                     })
                   }),
                   sessionInfo=sessionInfo(),
                   call=mcall
  )
  saveRDS(pipinfo, file=paste0(output.prefix,"runPipelineInfo.rds"))
  
  names(resfiles) <- names(datasets)
  res <- lapply(resfiles, readRDS)
  res <- aggregatePipelineResults(res, pipelineDef)
  saveRDS(res, file=paste0(output.prefix,"aggregated.rds"))
  
  res
}


# build function call (for a step of runPipeline) from list of arguments
.mycall <- function(fn, args){
  if(is.function(fn)) fn <- deparse(match.call()$fn)
  args <- paste(paste(names(args), sapply(args, FUN=function(x){
    if(is.numeric(x)) return(x)
    paste0("\"",x,"\"")
  }), sep="="), collapse=", ")
  parse(text=paste0(fn, "(x=x, ", args, ")"))
}

.checkPipArgs <- function(alternatives, pipDef=NULL){
  if(any(grepl(";|=",names(alternatives)))) 
    stop("Some of the pipeline arguments contain unaccepted characters ",
      "(e.g. ';' or '=').")
  if(any(sapply(alternatives, FUN=function(x) any(grepl(";|=",x)))))
    stop("Some of the alternative argument values contain unaccepted ",
      "characters (e.g. ';' or '=').")
  if(!is.null(pipDef)){
    def <- pipDef@defaultArguments
    for(f in names(alternatives)) def[[f]] <- alternatives[[f]]
    args <- arguments(pipDef)
    if(!all(unlist(args) %in% names(def))){
      missingParams <- setdiff(as.character(unlist(args)), names(def))
      stop("`alternatives` should have entries for the following slots defined",
        " in the pipeline: ", paste(missingParams ,collapse=", "))
    }
    if(!all( sapply(def, FUN=length)>0)){
      stop("All steps of `alternatives` should contain at least one option.")
    }
    alternatives <- def
  }
  alternatives
}


.args2name <- function(x, alt){
  x2 <- mapply(a=alt,i=as.numeric(x),FUN=function(a,i) a[i])
  paste( paste0( names(alt), "=", x2), collapse=";" )
}
