#include <algorithm> // perf stats
#include <cstring>
#include <iomanip>
#include <iostream>
#include <numeric> // perf stats
#include <unistd.h>
#include <vector>

#include "CPPProcess.h"
//#include "HelAmps_sm.h"

#include "vrambo.h"
#include "timer.h"

#define TIMERTYPE std::chrono::high_resolution_clock

bool is_number(const char *s) {
  const char *t = s;
  while (*t != '\0' && isdigit(*t))
    ++t;
  return strlen(s) == t - s;
}

int usage(char* argv0, int ret = 1) {
  std::cout << "Usage: " << argv0 
            << " [--verbose|-v] [--debug|-d] [--performance|-p]"
            << " [#gpuBlocksPerGrid #gpuThreadsPerBlock] #iterations" << std::endl;
  return ret;
}

int main(int argc, char **argv) {
  bool verbose = false, debug = false, perf = false;
  int niter = 0;
  int gpublocks = 1;
  int gputhreads = 1;
  std::vector<int> numvec;
  Timer<TIMERTYPE> timer;
  std::vector<float> wavetimes;


  for (int argn = 1; argn < argc; ++argn) {
    if (strcmp(argv[argn], "--verbose") == 0 || strcmp(argv[argn], "-v") == 0)
      verbose = true;
    else if (strcmp(argv[argn], "--debug") == 0 ||
             strcmp(argv[argn], "-d") == 0)
      debug = true;
    else if (strcmp(argv[argn], "--performance") == 0 ||
             strcmp(argv[argn], "-p") == 0)
      perf = true;
    else if (is_number(argv[argn]))
      numvec.push_back(atoi(argv[argn]));
    else
      return usage(argv[0]);
  }
  int veclen = numvec.size();
  if (veclen == 3) {
    gpublocks = numvec[0];
    gputhreads = numvec[1];
    niter = numvec[2];
  } else if (veclen == 1) {
    niter = numvec[0];
  } else {
    return usage(argv[0]);
  }

  if (niter == 0)
    return usage(argv[0]);

  //std::cout << "Calling cudaFree... " << std::endl;
  gpuErrchk3( cudaFree( 0 ) ); // SLOW!
  //std::cout << "Calling cudaFree... done" << std::endl;

  if (verbose)
    std::cout << "# iterations: " << niter << std::endl;

  // Create a process object
  CPPProcess process(niter, gpublocks, gputhreads, verbose, debug);

  // Read param_card and set parameters
  process.initProc("../../Cards/param_card.dat");

  const double energy = 1500;

  const int meGeVexponent = -(2 * process.nexternal - 8);

  // Memory structures for input momenta and output matrix elements on host and device
  const int ndim = gpublocks * gputhreads;
  const int npar = process.nexternal; // for this process (eemumu): npar=4 (e+, e-, mu+, mu-)
  const int nparf = npar - process.ninitial; // for this process (eemumu): nparf=2 (mu+, mu-)
  const int np4 = 4; // dimension of 4-momenta (E,px,py,pz): copy all of them from rambo

  double* rnarray = new double[nparf*np4*ndim]; // can be SOA or AOS

  int nbytesMomenta = np4*npar*ndim * sizeof(double);
  //double* hstMomenta = new double[npar*np4*ndim]; // SOA[npar][np4][ndim] (previously was: lp)
  double* hstMomenta = 0; // SOA[npar][np4][ndim] (previously was: lp)
  gpuErrchk3( cudaMallocHost( &hstMomenta, nbytesMomenta ) );
  double* devMomenta = 0; // (previously was: allMomenta)
  gpuErrchk3( cudaMalloc( &devMomenta, nbytesMomenta ) );

  int nbytesMEs = ndim * sizeof(double);
  //double* hstMEs = new double[ndim]; // (previously was: meHostPtr)
  double* hstMEs = 0; // (previously was: meHostPtr)
  gpuErrchk3( cudaMallocHost( &hstMEs, nbytesMEs ) );
  double* devMEs = 0; // (previously was: meDevPtr)
  gpuErrchk3( cudaMalloc( &devMEs, nbytesMEs ) );

#ifdef RAMBO_USES_SOA
  ////double (*rmbMomenta)[np4][ndim] = new double[npar][np4][ndim]; // SOA[npar][np4][ndim] (previously was: p)
  //double* rmbMomenta = new double[npar*np4*ndim]; // SOA[npar][np4][ndim] (previously was: p)
  double* rmbMomenta = hstMomenta; // same structure, no need to copy
#else
  double (*rmbMomenta)[npar][np4] = new double[ndim][npar][np4]; // AOS[ndim][npar][np4] (previously was: p)
#endif

  std::vector<double> matrixelementvector;

  double masses[npar];  
  for (int ipar = 0; ipar < npar; ++ipar) // loop over nexternal particles
    masses[ipar] = process.getMasses()[ipar];

  for (int iiter = 0; iiter < niter; ++iiter) {
    //std::cout << "Iteration #" << iiter+1 << " of " << niter << std::endl;
    
    // STEP 1 OF 3
    // Generate all relevant numbers to build ndim events (i.e. ndim phase space points)
    generateRnArray( rnarray, nparf, ndim );
    //std::cout << "Got random numbers" << std::endl;

    // STEP 2 OF 3
    // Map random numbers to particle momenta for each of ndim events
    double weights[ndim]; // dummy in this test application
    get_momenta( process.ninitial, energy, masses, rnarray, (double*)rmbMomenta, weights, npar, ndim );
    //std::cout << "Got momenta" << std::endl;

#ifdef RAMBO_USES_SOA
    // Use momenta from rambo as they are (no need to copy)
#else
    // Set SOA momenta for this event by copying them from the rambo AOS output
    for (int idim = 0; idim < ndim; ++idim)
      for (int ipar = 0; ipar < npar; ++ipar)
        for (int ip4 = 0; ip4 < np4; ++ip4)
          hstMomenta[ipar*ndim*np4 + ip4*ndim + idim] = // SOA[npar][np4][ndim]
            rmbMomenta[idim][ipar][ip4]; // AOS[ndim][npar][np4]
#endif
    gpuErrchk3( cudaMemcpy( devMomenta, hstMomenta, nbytesMomenta, cudaMemcpyHostToDevice ) );

    // STEP 3 OF 3
    // Evaluate matrix elements for all ndim events
    if (perf) timer.Start();

    sigmaKin<<<gpublocks, gputhreads>>>(devMomenta,  devMEs);//, debug, verbose);
    gpuErrchk3( cudaPeekAtLastError() );

    gpuErrchk3( cudaMemcpy( hstMEs, devMEs, nbytesMEs, cudaMemcpyDeviceToHost ) );

    if (verbose)
      std::cout << "***********************************" << std::endl
                << "Iteration #" << iiter+1 << " of " << niter << std::endl;

    if (perf) {
      float gputime = timer.GetDuration();
      wavetimes.push_back(gputime);
      if (verbose)
        std::cout << "Wave function time: " << gputime << std::endl;
    }

    if (verbose || perf) {

      for (int idim = 0; idim < ndim; ++idim) {

        if (verbose) {
          std::cout << "Momenta:" << std::endl;
          for (int ipar = 0; ipar < npar; ipar++)
          {
#ifdef RAMBO_USES_SOA
            std::cout << std::setw(4) << ipar + 1
                      << setiosflags(std::ios::scientific)
  //<< std::setw(14) << rmbMomenta[ipar][0][idim]
                      << std::setw(14) << rmbMomenta[ipar*ndim*np4 + 0*ndim + idim]
                      << setiosflags(std::ios::scientific)
  //<< std::setw(14) << rmbMomenta[ipar][1][idim]
                      << std::setw(14) << rmbMomenta[ipar*ndim*np4 + 1*ndim + idim]
                      << setiosflags(std::ios::scientific)
  //<< std::setw(14) << rmbMomenta[ipar][2][idim]
                      << std::setw(14) << rmbMomenta[ipar*ndim*np4 + 2*ndim + idim]
                      << setiosflags(std::ios::scientific)
  //<< std::setw(14) << rmbMomenta[ipar][3][idim]
                      << std::setw(14) << rmbMomenta[ipar*ndim*np4 + 3*ndim + idim]
                      << std::endl;
#else
            std::cout << std::setw(4) << ipar + 1
                      << setiosflags(std::ios::scientific)
                      << std::setw(14) << rmbMomenta[idim][ipar][0]
                      << setiosflags(std::ios::scientific)
                      << std::setw(14) << rmbMomenta[idim][ipar][1]
                      << setiosflags(std::ios::scientific)
                      << std::setw(14) << rmbMomenta[idim][ipar][2]
                      << setiosflags(std::ios::scientific)
                      << std::setw(14) << rmbMomenta[idim][ipar][3]
                      << std::endl;
#endif
          }
          std::cout << std::string(80, '-') << std::endl;
        }

        // Display matrix elements
        for (int iproc = 0; iproc < process.nprocesses; iproc++) {
          if (verbose)
            std::cout << " Matrix element = "
                      //	 << setiosflags(ios::fixed) << setprecision(17)
                      << hstMEs[iproc*1 + idim] << " GeV^" << meGeVexponent << std::endl;
          if (perf)
            matrixelementvector.push_back(hstMEs[iproc*1 + idim]);
        }
        if (verbose)
          std::cout << std::string(80, '-') << std::endl;
      }
    } else if (!debug) {
      std::cout << ".";
    }
  }

  if (!(verbose || debug || perf)) {
    std::cout << std::endl;
  }

  if (perf) {
    float sum = std::accumulate(wavetimes.begin(), wavetimes.end(), 0.0);
    int num_wts = wavetimes.size();
    float mean = sum / num_wts;
    float sq_sum = std::inner_product(wavetimes.begin(), wavetimes.end(),
                                      wavetimes.begin(), 0.0);
    float stdev = std::sqrt(sq_sum / num_wts - mean * mean);
    std::vector<float>::iterator mintime =
        std::min_element(wavetimes.begin(), wavetimes.end());
    std::vector<float>::iterator maxtime =
        std::max_element(wavetimes.begin(), wavetimes.end());

    int num_mes = matrixelementvector.size();
    float sumelem = std::accumulate(matrixelementvector.begin(), matrixelementvector.end(), 0.0);
    float meanelem = sumelem / num_mes;
    float sqselem = std::inner_product(matrixelementvector.begin(), matrixelementvector.end(), 
                                       matrixelementvector.begin(), 0.0);
    float stdelem = std::sqrt(sqselem / num_mes - meanelem * meanelem);
    std::vector<double>::iterator maxelem = std::max_element(
        matrixelementvector.begin(), matrixelementvector.end());
    std::vector<double>::iterator minelem = std::min_element(
        matrixelementvector.begin(), matrixelementvector.end());

    std::cout << "***********************************" << std::endl
              << "NumIterations         = " << niter << std::endl
              << "NumThreadsPerBlock    = " << gputhreads << std::endl
              << "NumBlocksPerGrid      = " << gpublocks << std::endl
              << "-----------------------------------" << std::endl
              << "NumberOfEntries       = " << num_wts << std::endl
              << std::scientific
              << "TotalTimeInWaveFuncs  = " << sum << " sec" << std::endl
              << "MeanTimeInWaveFuncs   = " << mean << " sec" << std::endl
              << "StdDevTimeInWaveFuncs = " << stdev << " sec" << std::endl
              << "MinTimeInWaveFuncs    = " << *mintime << " sec" << std::endl
              << "MaxTimeInWaveFuncs    = " << *maxtime << " sec" << std::endl
              << "-----------------------------------" << std::endl
              << "ProcessID:            = " << getpid() << std::endl
              << "NProcesses            = " << process.nprocesses << std::endl
              << "NumMatrixElements     = " << num_mes << std::endl
              << "MatrixElementsPerSec  = " << num_mes/sum << " sec^-1" << std::endl;

    std::cout << "***********************************" << std::endl
              << "NumMatrixElements     = " << num_mes << std::endl
              << std::scientific
              << "MeanMatrixElemValue   = " << meanelem << " GeV^" << meGeVexponent << std::endl
              << "StdErrMatrixElemValue = " << stdelem/sqrt(num_mes) << " GeV^" << meGeVexponent << std::endl
              << "StdDevMatrixElemValue = " << stdelem << " GeV^" << meGeVexponent << std::endl
              << "MinMatrixElemValue    = " << *minelem << " GeV^" << meGeVexponent << std::endl
              << "MaxMatrixElemValue    = " << *maxelem << " GeV^" << meGeVexponent << std::endl;
  }

  delete[] rnarray;

#ifndef RAMBO_USES_SOA
  delete[] rmbMomenta;
#endif

  //delete[] hstMEs;
  //delete[] hstMomenta;
  gpuErrchk3( cudaFreeHost( hstMEs ) );
  gpuErrchk3( cudaFreeHost( hstMomenta ) );

  gpuErrchk3( cudaFree( devMEs ) );
  gpuErrchk3( cudaFree( devMomenta ) );

  gpuErrchk3( cudaDeviceReset() ); // this is needed by cuda-memcheck --leak-check full
}
