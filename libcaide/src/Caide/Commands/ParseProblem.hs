module Caide.Commands.ParseProblem(
      cmd
) where

import Control.Monad (forM_)
import Data.List (find)
import qualified Data.Text as T

import Filesystem (createDirectory, writeTextFile)
import qualified Filesystem.Path as F
import Filesystem.Path.CurrentOS (decodeString, (</>))

import Caide.Types
import Caide.Codeforces.Parser (codeforcesParser)

cmd :: CommandHandler
cmd = CommandHandler
    { command = "problem"
    , description = "Parses problem description and creates scaffold solution"
    , usage = ""
    , action = parseProblem
    }

parsers :: [ProblemParser]
parsers = [codeforcesParser]

parseProblem :: F.FilePath -> [String] -> IO ()
parseProblem caideRoot args = do
    let url = head $ map T.pack args
        parser = find (`matches` url) parsers
    case parser of
        Nothing -> putStrLn "This online judge is not supported"
        Just p  -> do
            parseResult <- p `parse` url
            case parseResult of
                Left err -> putStrLn $ "Encountered a problem while parsing:\n" ++ err
                Right (problem, samples) -> do
                    let problemDir = caideRoot </> decodeString (problemId problem)
                    createDirectory False problemDir
                    forM_ (zip samples [1::Int ..]) $ \(sample, i) -> do
                        let inFile  = problemDir </> decodeString ("case" ++ show i ++ ".in")
                            outFile = problemDir </> decodeString ("case" ++ show i ++ ".out")
                        writeTextFile inFile  $ testCaseInput sample
                        writeTextFile outFile $ testCaseOutput sample
                    putStrLn $ "Problem successfully parsed into folder " ++ problemId problem