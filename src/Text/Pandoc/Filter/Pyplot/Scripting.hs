{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Text.Pandoc.Filter.Pyplot.Scripting
Copyright   : (c) Laurent P René de Cotret, 2019
License     : MIT
Maintainer  : laurent.decotret@outlook.com
Stability   : internal
Portability : portable

This module defines types and functions that help
with running Python scripts.
-}
module Text.Pandoc.Filter.Pyplot.Scripting
    ( runTempPythonScript
    , hasBlockingShowCall
    , PythonScript
    , ScriptResult(..)
    ) where

import           Data.Hashable        (hash)
import           Data.Monoid          (Any(..))
import           Data.Text            (Text)
import qualified Data.Text            as T
import qualified Data.Text.IO         as T

import           System.Exit          (ExitCode (..))
import           System.FilePath      ((</>))
import           System.IO.Temp       (getCanonicalTemporaryDirectory)
import           System.Process.Typed (runProcess, shell)

-- | String representation of a Python script
type PythonScript = Text

-- | Possible result of running a Python script
data ScriptResult
    = ScriptSuccess
    | ScriptFailure Int

-- | Take a python script in string form, write it in a temporary directory,
-- then execute it.
runTempPythonScript :: String          -- ^ Interpreter (e.g. "python" or "python35")
                    -> PythonScript    -- ^ Content of the script
                    -> IO ScriptResult -- ^ Result with exit code.
runTempPythonScript interpreter script = do
    -- We involve the script hash as a temporary filename
    -- so that there is never any collision
    scriptPath <- (</> hashedPath) <$> getCanonicalTemporaryDirectory
    T.writeFile scriptPath script

    ec <- runProcess $ shell $ mconcat [interpreter, " ", show scriptPath]
    case ec of
        ExitSuccess      -> return   ScriptSuccess
        ExitFailure code -> return $ ScriptFailure code
    where
        hashedPath = show . hash $ script

-- | Detect the presence of a blocking show call, for example "plt.show()"
hasBlockingShowCall :: PythonScript -> Bool
hasBlockingShowCall script =
    anyOf
        [ "plt.show()" `elem` scriptLines
        , "pyplot.show()" `elem` scriptLines
        , "matplotlib.pyplot.show()" `elem` scriptLines
        ]
  where
    scriptLines = T.lines script
    anyOf xs = getAny $ mconcat $ Any <$> xs