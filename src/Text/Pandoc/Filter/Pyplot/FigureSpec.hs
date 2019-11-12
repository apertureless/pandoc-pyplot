{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE TemplateHaskell   #-}

{-|
Module      : $header$
Copyright   : (c) Laurent P René de Cotret, 2019
License     : MIT
Maintainer  : laurent.decotret@outlook.com
Stability   : internal
Portability : portable

This module defines types and functions that help
with keeping track of figure specifications
-}
module Text.Pandoc.Filter.Pyplot.FigureSpec
    ( FigureSpec(..)
    , SaveFormat(..)
    , saveFormatFromString
    , toImage
    , sourceCodePath
    , figurePath
    , addPlotCapture
    , parseFigureSpec
    -- for testing purposes
    , extension
    ) where

import           Control.Monad                   (join)
import           Control.Monad.IO.Class          (liftIO)
import           Control.Monad.Reader            (ask)

import           Data.Default.Class              (def)
import           Data.Hashable                   (hash)
import           Data.List                       (intersperse)
import qualified Data.Map.Strict                 as Map
import           Data.Maybe                      (fromMaybe)
import           Data.Monoid                     ((<>))
import           Data.Text                       (Text, pack)
import qualified Data.Text.IO                    as TIO
import           Data.Version                    (showVersion)

import           Paths_pandoc_pyplot             (version)

import           System.FilePath                 (FilePath, addExtension,
                                                  makeValid, normalise,
                                                  replaceExtension, (</>))

import           Text.Pandoc.Builder             (fromList, imageWith, link,
                                                  para, toList)
import           Text.Pandoc.Definition          (Block (..), Inline,
                                                  Pandoc (..))
import           Text.Shakespeare.Text           (st)

import           Text.Pandoc.Class               (runPure)
import           Text.Pandoc.Extensions          (Extension (..),
                                                  extensionsFromList)
import           Text.Pandoc.Options             (ReaderOptions (..))
import           Text.Pandoc.Readers             (readMarkdown)

import           Text.Pandoc.Filter.Pyplot.Types


-- | Determine inclusion specifications from @Block@ attributes.
-- Note that the @".pyplot"@ OR @.plotly@ class is required, but all other
-- parameters are optional.
parseFigureSpec :: Block -> PyplotM (Maybe FigureSpec)
parseFigureSpec (CodeBlock (id', cls, attrs) content)
    | "pyplot" `elem` cls = Just <$> figureSpec Matplotlib
    | "plotly" `elem` cls = Just <$> figureSpec Plotly
    | otherwise = return Nothing
  where
    attrs'        = Map.fromList attrs
    filteredAttrs = filter (\(k, _) -> k `notElem` inclusionKeys) attrs
    includePath   = Map.lookup includePathKey attrs'
    header        = "# Generated by pandoc-pyplot " <> ((pack . showVersion) version)

    figureSpec :: RenderingLibrary -> PyplotM FigureSpec
    figureSpec lib = do
        config <- ask
        includeScript <- fromMaybe
                            (return $ defaultIncludeScript config)
                            ((liftIO . TIO.readFile) <$> includePath)
        return $
            FigureSpec
                { caption      = Map.findWithDefault mempty captionKey attrs'
                , withLinks    = fromMaybe (defaultWithLinks config) $ readBool <$> Map.lookup withLinksKey attrs'
                , script       = mconcat $ intersperse "\n" [header, includeScript, pack content]
                , saveFormat   = fromMaybe (defaultSaveFormat config) $ join $ saveFormatFromString <$> Map.lookup saveFormatKey attrs'
                , directory    = makeValid $ Map.findWithDefault (defaultDirectory config) directoryKey attrs'
                , dpi          = fromMaybe (defaultDPI config) $ read <$> Map.lookup dpiKey attrs'
                , renderingLib = lib
                , tightBbox    = isTightBbox config
                , transparent  = isTransparent config
                , blockAttrs   = (id', filter (\c -> c `notElem` ["pyplot", "plotly"]) cls, filteredAttrs)
                }

parseFigureSpec _ = return Nothing


-- | Convert a @FigureSpec@ to a Pandoc block component.
-- Note that the script to generate figure files must still
-- be run in another function.
toImage :: FigureSpec -> Block
toImage spec = head . toList $ para $ imageWith attrs' target' "fig:" caption'
    -- To render images as figures with captions, the target title
    -- must be "fig:"
    -- Janky? yes
    where
        attrs'       = blockAttrs spec
        target'      = figurePath spec
        withLinks'   = withLinks spec
        srcLink      = link (replaceExtension target' ".txt") mempty "Source code"
        hiresLink    = link (hiresFigurePath spec) mempty "high res."
        captionText  = fromList $ fromMaybe mempty (captionReader $ caption spec)
        captionLinks = mconcat [" (", srcLink, ", ", hiresLink, ")"]
        caption'     = if withLinks' then captionText <> captionLinks else captionText


-- | Determine the path a figure should have.
figurePath :: FigureSpec -> FilePath
figurePath spec = normalise $ directory spec </> stem spec
  where
    stem = flip addExtension ext . show . hash
    ext  = extension . saveFormat $ spec


-- | Determine the path to the source code that generated the figure.
sourceCodePath :: FigureSpec -> FilePath
sourceCodePath = normalise . flip replaceExtension ".txt" . figurePath


-- | The path to the high-resolution figure.
hiresFigurePath :: FigureSpec -> FilePath
hiresFigurePath spec = normalise $ flip replaceExtension (".hires" <> ext) . figurePath $ spec
  where
    ext = extension . saveFormat $ spec


-- | Modify a Python plotting script to save the figure to a filename.
-- An additional file will also be captured.
addPlotCapture :: FigureSpec   -- ^ Path where to save the figure
               -> PythonScript -- ^ Code block with added capture
addPlotCapture spec = mconcat
        [ script spec <> "\n"
        -- Note that the high-resolution figure always has non-transparent background
        -- because it is difficult to see the image when opened directly
        -- in Chrome, for example.
        , plotCapture (renderingLib spec) (figurePath spec) (dpi spec) (transparent spec) (tight')
        , plotCapture (renderingLib spec) (hiresFigurePath spec) (minimum [200, 2 * dpi spec]) False (tight')
        ]
  where
    tight' = if tightBbox spec then ("'tight'" :: Text) else ("None" :: Text)
    -- Note that, especially for Windows, raw strings (r"...") must be used because path separators might
    -- be interpreted as escape characters
    plotCapture Matplotlib = captureMatplotlib
    plotCapture Plotly     = capturePlotly


type Tight = Text
type DPI = Int
type IsTransparent = Bool
type RenderingFunc = (FilePath -> DPI -> IsTransparent -> Tight -> PythonScript)


-- | Capture plot from Matplotlib
-- Note that, especially for Windows, raw strings (r"...") must be used because path separators might
-- be interpreted as escape characters
captureMatplotlib :: RenderingFunc
captureMatplotlib fname' dpi' transparent' tight' = [st|
import matplotlib.pyplot as plt
plt.savefig(r"#{fname'}", dpi=#{dpi'}, transparent=#{transparent''}, bbox_inches=#{tight'})
|]
    where
        transparent'' :: Text
        transparent'' = if transparent' then "True" else "False"

-- | Capture Plotly figure
--
-- We are trying to emulate the behavior of @matplotlib.pyplot.savefig@ which
-- knows the "current figure". This saves us from contraining users to always
-- have the same Plotly figure name, e.g. @fig@ in all examples on plot.ly
capturePlotly :: RenderingFunc
capturePlotly fname' _ _ _ = [st|
import plotly.graph_objects as go
__current_plotly_figure = next(obj for obj in globals().values() if type(obj) == go.Figure)
__current_plotly_figure.write_image("#{fname'}")
|]


-- | Reader options for captions.
readerOptions :: ReaderOptions
readerOptions = def
    {readerExtensions =
        extensionsFromList
            [ Ext_tex_math_dollars
            , Ext_superscript
            , Ext_subscript
            , Ext_raw_tex
            ]
    }


-- | Read a figure caption in Markdown format. LaTeX math @$...$@ is supported,
-- as are Markdown subscripts and superscripts.
captionReader :: String -> Maybe [Inline]
captionReader t = either (const Nothing) (Just . extractFromBlocks) $ runPure $ readMarkdown' (pack t)
    where
        readMarkdown' = readMarkdown readerOptions

        extractFromBlocks (Pandoc _ blocks) = mconcat $ extractInlines <$> blocks

        extractInlines (Plain inlines)          = inlines
        extractInlines (Para inlines)           = inlines
        extractInlines (LineBlock multiinlines) = join multiinlines
        extractInlines _                        = []


-- | Flexible boolean parsing
readBool :: String -> Bool
readBool s | s `elem` ["True",  "true",  "'True'",  "'true'",  "1"] = True
           | s `elem` ["False", "false", "'False'", "'false'", "0"] = False
           | otherwise = error $ mconcat ["Could not parse '", s, "' into a boolean. Please use 'True' or 'False'"]
