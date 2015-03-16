{-| Unicode input/output is broken.
    Use these functions to read and write text files in UTF8.
-}
module Filesystem.Util(
      readTextFile
    , writeTextFile
    , appendTextFile
) where

import Control.Applicative ((<$>))

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)

import qualified Filesystem.Path as F
import qualified Filesystem.Path.CurrentOS as F


import Data.Text.Encoding.Util (tryDecodeUtf8, universalNewlineConversionOnInput, universalNewlineConversionOnOutput)


-- | Read a text file. Return @Left message@ in case of a decoding error,
-- or @Right contents@ in case of success.
readTextFile :: F.FilePath -> IO (Either T.Text T.Text)
readTextFile filePath = do
    decodeResult <- tryDecodeUtf8 <$> BS.readFile (F.encodeString filePath)
    case decodeResult of
        Left err -> return $ Left err
        Right s  -> return $ Right $ universalNewlineConversionOnInput s

writeTextFile :: F.FilePath -> T.Text -> IO ()
writeTextFile filePath text = BS.writeFile (F.encodeString filePath) .
    encodeUtf8 . universalNewlineConversionOnOutput $ text

appendTextFile :: F.FilePath -> T.Text -> IO ()
appendTextFile filePath text = BS.appendFile (F.encodeString filePath) .
    encodeUtf8 . universalNewlineConversionOnOutput $ text
