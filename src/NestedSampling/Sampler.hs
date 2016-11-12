module NestedSampling.Sampler where

import System.IO (hFlush, stdout)
import Control.Monad (replicateM)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified System.Random.MWC as MWC

import NestedSampling.SpikeSlab
import NestedSampling.RNG

-- A sampler
data Sampler = Sampler
               {
                   numParticles      :: {-# UNPACK #-} !Int,
                   mcmcSteps         :: {-# UNPACK #-} !Int,
                   theParticles      :: !(V.Vector (U.Vector Double)),
                   theLogLikelihoods :: !(U.Vector Double),
                   iteration         :: {-# UNPACK #-}!Int
               } deriving Show

-- | Choose a particle to copy, that isn't number k.
chooseCopy :: Int -> Int -> IO Int
chooseCopy k n = MWC.withSystemRandom . MWC.asGenIO $ loop where
  loop prng = do
    index <- MWC.uniformR (0, n - 1) prng
    if   index == k
    then loop prng
    else return index

-- Generate a sampler with n particles and m mcmc steps
generateSampler :: Int -> Int -> IO Sampler
generateSampler n m
    | n <= 1    = undefined
    | m <= 0    = undefined
    | otherwise = do
        putStr ("Generating " ++ (show n) ++ " particles\
                        \ from the prior...")
        hFlush stdout
        theParticles <- V.replicateM n fromPrior
        let lls = V.map logLikelihood theParticles
        putStrLn "done."
        return Sampler {numParticles=n, mcmcSteps=m,
                        theParticles=theParticles,
                        theLogLikelihoods=U.convert lls, iteration=1}

-- Find the index and the log likelihood value of the worst particle
--
-- NB (jtobin):
--   It may be better to use something like a heap so that we can access the
--   min element in O(1).
findWorstParticle :: Sampler -> (Int, Double)
findWorstParticle sampler = (idx, U.unsafeIndex lls idx)
    where
        idx = U.minIndex lls
        lls = theLogLikelihoods sampler

-- Function to do a single metropolis update
-- Input: A vector of parameters and a loglikelihood threshold
-- Output: An IO action which would return a new vector of parameters
-- and its log likelihood
metropolisUpdate :: Double -> ((U.Vector Double), Double)
                                -> IO ((U.Vector Double), Double)
metropolisUpdate threshold (x, logL) = do
    (proposal, logH) <- perturb x
    let a = exp logH
    uu <- rand
    let llProposal = logLikelihood proposal
    let accept = (uu < a) && (llProposal > threshold)
    let newParticle = if accept then proposal else x
    let newLogL = if accept then llProposal else logL
    return (newParticle, newLogL)

-- Function to do many metropolis updates
metropolisUpdates :: Int -> Double -> ((U.Vector Double), Double)
                                -> IO ((U.Vector Double), Double)
metropolisUpdates n threshold (x, logL)
    | n < 0     = undefined
    | n == 0    = do
                    return (x, logL)
    | otherwise = do
                    next <- metropolisUpdate threshold (x, logL)
                    final <- metropolisUpdates (n-1) threshold next
                    return final

-- Do many NestedSampling iterations
nestedSamplingIterations :: Int -> Sampler -> IO Sampler
nestedSamplingIterations n sampler
    | n < 0     = undefined
    | n == 0    = do
                    return sampler
    | otherwise = do
                    next <- nestedSamplingIteration sampler
                    final <- nestedSamplingIterations (n-1) next
                    return final

-- Do a single NestedSampling iteration
nestedSamplingIteration :: Sampler -> IO Sampler
nestedSamplingIteration sampler = do
    let worst = findWorstParticle sampler
    putStr $ "Iteration " ++ (show $ iteration sampler) ++ ". "
    putStrLn $ "Log likelihood = " ++ (show $ snd worst) ++ "."
    let iWorst = fst worst
    let n = numParticles sampler
    copy <- chooseCopy iWorst n

    -- Copy a surviving particle
    let particle = (V.unsafeIndex (theParticles sampler) copy,
                        U.unsafeIndex (theLogLikelihoods sampler) copy)

    -- Do Metropolis
    let update = metropolisUpdates (mcmcSteps sampler) (snd worst)
    newParticle <- update particle

    -- Updated sampler
    let sampler' = Sampler { numParticles=(numParticles sampler),
                     mcmcSteps=(mcmcSteps sampler),
                     theParticles=V.fromList theParticles',
                     theLogLikelihoods=U.fromList theLogLikelihoods',
                     iteration=(iteration sampler + 1) } where

        theParticles' = [if i==iWorst then fst newParticle else
                            (V.unsafeIndex (theParticles sampler) i) |
                            i <- [0..(numParticles sampler - 1)]]

        theLogLikelihoods' = [if i==iWorst then snd newParticle else
                            (U.unsafeIndex (theLogLikelihoods sampler) i) |
                            i <- [0..(numParticles sampler - 1)]]
    return sampler'

