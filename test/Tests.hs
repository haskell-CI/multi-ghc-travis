{-# LANGUAGE ViewPatterns #-}
module Main (main) where

import Prelude ()
import Prelude.Compat

import HaskellCI hiding (main)

import Control.Arrow              (first)
import Data.Algorithm.Diff        (PolyDiff (..), getGroupedDiff)
import Distribution.Simple.Utils  (fromUTF8BS)
import System.Directory           (setCurrentDirectory)
import System.FilePath            (addExtension)
import Test.Tasty                 (TestName, TestTree, defaultMain, testGroup)
import Test.Tasty.Golden.Advanced (goldenTest)

import qualified Data.ByteString       as BS
import qualified Data.ByteString.Char8 as BS8
import qualified System.Console.ANSI   as ANSI

main :: IO ()
main = do
    setCurrentDirectory "fixtures/"
    defaultMain $ testGroup "fixtures"
        [ fixtureGoldenTest "all-versions"
        , fixtureGoldenTest "empty-line"
        , fixtureGoldenTest "fail-versions"
        , fixtureGoldenTest "irc-channels"
        , fixtureGoldenTest "messy"
        , fixtureGoldenTest "psql"
        , fixtureGoldenTest "travis-patch"
        , fixtureGoldenTest "matrix-extra"
        , testGroup "copy-fields"
            [ fixtureGoldenTest "copy-fields-all"
            , fixtureGoldenTest "copy-fields-some"
            , fixtureGoldenTest "copy-fields-none"
            ]
        ]

-- |
-- @
-- travisFromConfigFile ::
--    ... => ([String],Options) -> FilePath -> [String] -> Writer [String] m ()
-- @
fixtureGoldenTest :: FilePath -> TestTree
fixtureGoldenTest fp = testGroup fp
    [ fixtureGoldenTest' "travis" travisFromConfigFile
    , fixtureGoldenTest' "github" githubFromConfigFile
    , fixtureGoldenTest' "bash"   bashFromConfigFile
    ]
  where
    -- name acts as extension also
    fixtureGoldenTest' name generate = cabalGoldenTest name outputRef $ do
        (argv, opts') <- makeFlags
        let opts = opts'
              { optInputType      = Just InputTypeProject
              , optConfigMorphism = (\cfg -> cfg { cfgInsertVersion = False}) . optConfigMorphism opts'
              }
        let genConfig = generate argv opts projectfp
        first (fmap (lines . fromUTF8BS)) <$> runDiagnosticsT genConfig
      where
        outputRef = addExtension fp name
        projectfp = fp ++ ".project"

        readArgv :: IO [String]
        readArgv = do
            contents <- readFile $ addExtension fp "args"
            return $ filter (not . null)$ lines contents

        makeFlags :: IO ([String], Options)
        makeFlags = do
            argv <- readArgv
            let argv' = argv ++ [name, projectfp]
            (_fp, opts) <- parseOptions argv'
            return (argv', opts)

cabalGoldenTest
    :: TestName
    -> FilePath
    -> IO (Maybe [String], [String])
    -> TestTree
cabalGoldenTest name outRef act = goldenTest name readGolden (transform <$> act) cmp upd
  where
    readData :: FilePath -> IO [String]
    readData fp = lines . BS8.unpack <$> BS.readFile fp

    transform :: (Maybe [String], [String]) -> [String]
    transform (Nothing, diags) =
        [ "# FAILURE"
        ] ++
        [ "# " ++ w
        | w <- diags
        ]
    transform (Just contents, diags) =
        [ "# SUCCESS"
        ] ++
        [ "# " ++ w
        | w <- diags
        ] ++
        contents

    readGolden = readData outRef

    packData :: [String] -> BS.ByteString
    packData = BS8.pack . unlines

    upd (packData -> contents) = BS.writeFile outRef contents

    cmp x y | x == y = return Nothing
    cmp out1 out2 = return . Just . mconcat $
        [ diff out1 out2
        ]

    diff x y =
        ansiReset -- reset tasty's red color
        ++ unlines (concatMap f (getGroupedDiff x y))

    f (First xs)  = map (withAnsiRed . cons3 '-') xs
    f (Second ys) = map (withAnsiGreen . cons3 '+') ys
    -- we print unchanged lines too.
    -- we trim the contents a little.
    f (Both xs _) = map (cons3 ' ') (shorten xs)

    -- we add three characters, so the changed lines are easier to spot
    cons3 c cs = c : c : c : ' ' : cs

    ansiReset = ANSI.setSGRCode [ ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.White] -- default color: gray
    ansiRed   = ANSI.setSGRCode [ ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Red]
    ansiGreen = ANSI.setSGRCode [ ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Green]

    withAnsiRed s   = ansiRed ++ s ++ ansiReset
    withAnsiGreen s = ansiGreen ++ s ++ ansiReset

    -- for large thunks make ellipsis in between
    shorten xs
        | l < 15    = xs
        | otherwise = as ++ ["..."] ++ drop (l - 10) bs
      where
        l = length xs
        (as, bs) = splitAt 5 xs
