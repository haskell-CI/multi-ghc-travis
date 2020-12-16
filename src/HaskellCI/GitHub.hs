{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module HaskellCI.GitHub (
    makeGitHub,
    githubHeader,
) where

import HaskellCI.Prelude

import qualified Data.Map.Strict                 as Map
import qualified Data.Set                        as S
import qualified Distribution.Fields.Pretty      as C
import qualified Distribution.Package            as C
import qualified Distribution.Types.VersionRange as C
import qualified Distribution.Version            as C

import Cabal.Project
import HaskellCI.Auxiliary
import HaskellCI.Compiler
import HaskellCI.Config
import HaskellCI.Config.ConstraintSet
import HaskellCI.Config.Doctest
import HaskellCI.Config.HLint
import HaskellCI.Config.Installed
-- import HaskellCI.Config.Jobs
import HaskellCI.Config.PackageScope
import HaskellCI.Jobs
import HaskellCI.List
-- import HaskellCI.MonadErr
import HaskellCI.GitHub.Yaml
import HaskellCI.Package
import HaskellCI.Sh
import HaskellCI.ShVersionRange
import HaskellCI.Tools
import HaskellCI.VersionInfo

-------------------------------------------------------------------------------
-- GitHub header
-------------------------------------------------------------------------------

githubHeader :: Bool -> [String] -> [String]
githubHeader insertVersion argv =
    [ "This GitHub workflow config has been generated by a script via"
    , ""
    , "  haskell-ci " ++ unwords [ "'" ++ a ++ "'" | a <- argv ]
    , ""
    , "To regenerate the script (for example after adjusting tested-with) run"
    , ""
    , "  haskell-ci regenerate"
    , ""
    , "For more information, see https://github.com/haskell-CI/haskell-ci"
    , ""
    ] ++
    verlines ++
    [ "REGENDATA " ++ if insertVersion then show (haskellCIVerStr, argv) else show argv
    , ""
    ]
  where
    verlines
        | insertVersion = [ "version: " ++ haskellCIVerStr , "" ]
        | otherwise     = []

-------------------------------------------------------------------------------
-- GitHub
-------------------------------------------------------------------------------

{-
GitHub Actions–specific notes:

* We use -j2 for parallelism, as GitHub's virtual machines use 2 cores, per
  https://docs.github.com/en/free-pro-team@latest/actions/reference/specifications-for-github-hosted-runners#supported-runners-and-hardware-resources.
-}

makeGitHub
    :: [String]
    -> Config
    -> Project URI Void Package
    -> JobVersions
    -> Either ShError GitHub
makeGitHub _argv config@Config {..} prj jobs@JobVersions {..} = do
    let envEnv = Map.fromList
            [ ("GHC_VERSION", "${{ matrix.ghc }}")
            ]

    steps <- sequence $ buildList $ do
        githubRun' "apt" envEnv $ do
            sh "apt-get update"
            sh "apt-get install -y --no-install-recommends gnupg ca-certificates dirmngr curl git software-properties-common"
            sh "apt-add-repository -y 'ppa:hvr/ghc'"
            sh "apt-get update"
            sh "apt-get install -y ghc-$GHC_VERSION cabal-install-3.2" -- TODO: cabal version

        githubRun' "Set PATH and environment variables" envEnv $ do
            echo_to "$GITHUB_PATH" "$HOME/.cabal/bin"

            tell_env "LANG" "C.UTF-8"

            tell_env "CABAL_DIR"    "$HOME/.cabal"
            tell_env "CABAL_CONFIG" "$HOME/.cabal/config"

            let ghcdir = "/opt/ghc/$GHC_VERSION"
            let hc     = ghcdir ++ "/bin/ghc"

            sh ("HC=" ++ hc)
            tell_env "HC" "$HC"
            tell_env "HCPKG" (hc ++ "-pkg")
            tell_env "HADDOCK" (ghcdir ++ "/bin/haddock")

            -- TODO: configurable cabal version
            tell_env "CABAL" "/opt/cabal/3.2/bin/cabal -vnormal+nowrap"

            sh "HCNUMVER=$(${HC} --numeric-version|perl -ne '/^(\\d+)\\.(\\d+)\\.(\\d+)(\\.(\\d+))?$/; print(10000 * $1 + 100 * $2 + ($3 == 0 ? $5 != 1 : $3))')"
            tell_env "HCNUMVER" "$HCNUMVER"

            if_then_else (Range cfgTests)
                (tell_env' "ARG_TESTS" "--enable-tests")
                (tell_env' "ARG_TESTS" "--disable-tests")
            if_then_else (Range cfgBenchmarks)
                (tell_env' "ARG_BENCH" "--enable-benchmarks")
                (tell_env' "ARG_BENCH" "--disable-benchmarks")

            tell_env "ARG_COMPILER" ("--ghc --with-compiler=" ++ hc)

            tell_env "GHCJSARITH" "0"

        githubRun "env" $ do
            sh "env"

        githubRun "write cabal config" $ do
            sh "mkdir -p $CABAL_DIR"
            cat "$CABAL_CONFIG" $ unlines
                [ "remote-build-reporting: anonymous"
                , "write-ghc-environment-files: always"
                , "remote-repo-cache: $CABAL_DIR/packages"
                , "logs-dir:          $CABAL_DIR/logs"
                , "world-file:        $CABAL_DIR/world"
                , "extra-prog-path:   $CABAL_DIR/bin"
                , "symlink-bindir:    $CABAL_DIR/bin"
                , "installdir:        $CABAL_DIR/bin"
                , "build-summary:     $CABAL_DIR/logs/build.log"
                , "store-dir:         $CABAL_DIR/store"
                , "install-dirs user"
                , "  prefix: $CABAL_DIR"
                , "repository hackage.haskell.org"
                , "  url: http://hackage.haskell.org/"
                ]
            sh "cat $CABAL_CONFIG"

            -- TODO: head.hackage

        githubRun "versions" $ do
            sh "$HC --version || true"
            sh "$HC --print-project-git-commit-id || true"
            sh "$CABAL --version || true"

        githubRun "update cabal index" $ do
            sh "$CABAL v2-update -v"

        when (doctestEnabled || cfgHLintEnabled cfgHLint) $ githubUses "cache (tools)" "actions/cache@v2"
            [ ("key", "${{ runner.os }}-${{ matrix.ghc }}-tools")
            , ("path", "~/.cabal/store-tools")
            ]

        githubRun "install cabal-plan" $ do
            sh "mkdir -p $HOME/.cabal/bin"
            sh "curl -sL https://github.com/haskell-hvr/cabal-plan/releases/download/v0.6.2.0/cabal-plan-0.6.2.0-x86_64-linux.xz > cabal-plan.xz"
            sh "echo 'de73600b1836d3f55e32d80385acc055fd97f60eaa0ab68a755302685f5d81bc  cabal-plan.xz' | sha256sum -c -"
            sh "xz -d < cabal-plan.xz > $HOME/.cabal/bin/cabal-plan"
            sh "rm -f cabal-plan.xz"
            sh "chmod a+x $HOME/.cabal/bin/cabal-plan"

        when doctestEnabled $ githubRun "install doctest" $ do
            let range = (Range (cfgDoctestEnabled cfgDoctest) /\ doctestJobVersionRange)
            sh_if range "$CABAL --store-dir=$HOME/cabal/store-tools v2-install $ARG_COMPILER --ignore-project -j2 doctest --constraint='doctest ^>=0.17'"
            sh_if range "doctest --version"

        -- TODO: install HLint

        githubUses "checkout" "actions/checkout@v2"
            [ ("path", "source")
            ]

        githubRun "sdist" $ do
            sh "mkdir -p sdist"
            sh "cd source || false"
            sh "$CABAL sdist all --output-dir $GITHUB_WORKSPACE/sdist"

        githubRun "unpack" $ do
            sh "mkdir -p unpacked"
            sh "find sdist -maxdepth 1 -type f -name '*.tar.gz' -exec tar -C $GITHUB_WORKSPACE/unpacked -xzvf {} \\;"

        githubRun "generate cabal.project" $ do
            for_ pkgs $ \Pkg{pkgName} -> do
                sh $ pkgNameDirVariable' pkgName ++ "=\"$(find \"$GITHUB_WORKSPACE/unpacked\" -maxdepth 1 -type d -regex '.*/" ++ pkgName ++ "-[0-9.]*')\""
                tell_env (pkgNameDirVariable' pkgName) (pkgNameDirVariable pkgName)

            sh "touch cabal.project"
            sh "touch cabal.project.local"

            for_ pkgs $ \pkg ->
                echo_if_to (RangePoints $ pkgJobs pkg) "cabal.project" $ "packages: " ++ pkgNameDirVariable (pkgName pkg)

            -- per package options
            case cfgErrorMissingMethods of
                PackageScopeNone  -> pure ()
                PackageScopeLocal -> for_ pkgs $ \Pkg{pkgName,pkgJobs} -> do
                    let range = Range (C.orLaterVersion (C.mkVersion [8,2])) /\ RangePoints pkgJobs
                    echo_if_to range "cabal.project" $ "package " ++ pkgName
                    echo_if_to range "cabal.project" $ "    ghc-options: -Werror=missing-methods"
                PackageScopeAll   -> cat "cabal.project" $ unlines
                    [ "package *"
                    , "  ghc-options: -Werror=missing-methods"
                    ]

            -- extra cabal.project fields
            cat "cabal.project" $ C.showFields' (const []) 2 extraCabalProjectFields

            -- also write cabal.project.local file with
            -- @
            -- constraints: base installed
            -- constraints: array installed
            -- ...
            --
            -- omitting any local package names
            case normaliseInstalled cfgInstalled of
                InstalledDiff pns -> sh $ unwords
                    [ "$HCPKG list --simple-output --names-only"
                    , "| perl -ne 'for (split /\\s+/) { print \"constraints: $_ installed\\n\" unless /" ++ re ++ "/; }'"
                    , ">> cabal.project.local"
                    ]
                  where
                    pns' = S.map C.unPackageName pns `S.union` foldMap (S.singleton . pkgName) pkgs
                    re = "^(" ++ intercalate "|" (S.toList pns') ++ ")$"

                InstalledOnly pns | not (null pns') -> cat "cabal.project.local" $ unlines
                    [ "constraints: " ++ pkg ++ " installed"
                    | pkg <- S.toList pns'
                    ]
                  where
                    pns' = S.map C.unPackageName pns `S.difference` foldMap (S.singleton . pkgName) pkgs

                -- otherwise: nothing
                _ -> pure ()

            sh "cat cabal.project"
            sh "cat cabal.project.local"

        githubRun "dump install plan" $ do
            sh "$CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH --dry-run all"
            sh "cabal-plan"

        -- This a hack. https://github.com/actions/cache/issues/109
        -- Hashing Java - Maven style.
        githubUses "cache" "actions/cache@v2"
            [ ("key", "${{ runner.os }}-${{ matrix.ghc }}-${{ github.sha }}")
            , ("restore-keys", "${{ runner.os }}-${{ matrix.ghc }}-")
            , ("path", "~/.cabal/store")
            ]

        -- install dependencies
        when cfgInstallDeps $ githubRun "install dependencies" $ do
            sh "$CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks --dependencies-only -j2 all"
            sh "$CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH --dependencies-only -j2 all"

        -- build w/o tests benchs
        unless (equivVersionRanges C.noVersion cfgNoTestsNoBench) $ githubRun "build w/o tests" $ do
            sh "$CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks all"

        -- build
        githubRun "build" $ do
            sh "$CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH all"

        -- tests
        githubRun "tests" $ do
            let range = RangeGHC /\ Range (cfgTests /\ cfgRunTests) /\ hasTests
            sh_if range $ "$CABAL v2-test $ARG_COMPILER $ARG_TESTS $ARG_BENCH all" ++ testShowDetails

        -- doctest
        when doctestEnabled $ githubRun "doctest" $ do
            let doctestOptions = unwords $ cfgDoctestOptions cfgDoctest

            unless (null $ cfgDoctestFilterEnvPkgs cfgDoctest) $ do
                -- cabal-install mangles unit ids on the OSX,
                -- removing the vowels to make filepaths shorter
                let manglePkgNames :: String -> [String]
                    manglePkgNames n
                        | null cfgOsx = [n]
                        | otherwise   = [n, filter notVowel n]
                      where
                        notVowel c = notElem c ("aeiou" :: String)
                let filterPkgs = intercalate "|" $ concatMap (manglePkgNames . C.unPackageName) $ cfgDoctestFilterEnvPkgs cfgDoctest
                sh $ "perl -i -e 'while (<ARGV>) { print unless /package-id\\s+(" ++ filterPkgs ++ ")-\\d+(\\.\\d+)*/; }' .ghc.environment.*"

            for_ pkgs $ \Pkg{pkgName,pkgGpd,pkgJobs} ->
                when (C.mkPackageName pkgName `notElem` cfgDoctestFilterSrcPkgs cfgDoctest) $ do
                    for_ (doctestArgs pkgGpd) $ \args -> do
                        let args' = unwords args
                        let vr = Range (cfgDoctestEnabled cfgDoctest)
                              /\ doctestJobVersionRange
                              /\ RangePoints pkgJobs

                        unless (null args) $ do
                            change_dir_if vr $ pkgNameDirVariable pkgName
                            sh_if vr $ "doctest " ++ doctestOptions ++ " " ++ args'

        -- TODO: hlint

        -- cabal check
        when cfgCheck $ githubRun "cabal check" $ do
            for_ pkgs $ \Pkg{pkgName,pkgJobs} -> do
                let range = RangePoints pkgJobs
                change_dir_if range $ pkgNameDirVariable pkgName
                sh_if range "${CABAL} -vnormal check"

        -- haddock
        when (hasLibrary && not (equivVersionRanges C.noVersion cfgHaddock)) $ githubRun "haddock" $ do
            let range = RangeGHC /\ Range cfgHaddock
            sh_if range "$CABAL v2-haddock $ARG_COMPILER --with-haddock $HADDOCK $ARG_TESTS $ARG_BENCH all"

        -- unconstrained build
        unless (equivVersionRanges C.noVersion cfgUnconstrainted) $ githubRun "unconstrained build" $ do
            let range = Range cfgUnconstrainted
            sh_if range "rm -f cabal.project.local"
            sh_if range "$CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks all"

        -- constraint sets
        unless (null cfgConstraintSets) $ githubRun "prepare for constraint sets" $ do
            sh "rm -f cabal.project.local"

        for_ cfgConstraintSets $ \cs -> githubRun ("constraint set " ++ csName cs) $ do
            let sh_cs           = sh_if (Range (csGhcVersions cs))
            let sh_cs' r        = sh_if (Range (csGhcVersions cs) /\ r)
            let testFlag        = if csTests cs then "--enable-tests" else "--disable-tests"
            let benchFlag       = if csBenchmarks cs then "--enable-benchmarks" else "--disable-benchmarks"
            let constraintFlags = map (\x ->  "--constraint='" ++ x ++ "'") (csConstraints cs)
            let allFlags        = unwords (testFlag : benchFlag : constraintFlags)

            sh_cs $ "$CABAL v2-build $ARG_COMPILER " ++ allFlags ++ " all"
            when (csRunTests cs) $
                sh_cs' hasTests $ "$CABAL v2-test $ARG_COMPILER " ++ allFlags ++ " all"
            when (hasLibrary && csHaddock cs) $
                sh_cs $ "$CABAL v2-haddock $ARG_COMPILER " ++ withHaddock ++ " " ++ allFlags ++ " all"

    -- assembling everything
    return GitHub
        { ghOn = GitHubOn
            { ghBranches = cfgOnlyBranches
            }
        , ghJobs = Map.singleton "linux" GitHubJob
            { ghjName      = "Haskell-CI Linux"
            , ghjRunsOn    = "ubuntu-18.04" -- TODO: use cfgUbuntu
            , ghjSteps     = steps
            , ghjContainer = Just "buildpack-deps:bionic" -- use cfgUbuntu?
            , ghjMatrix    =
                [ GitHubMatrixEntry
                    { ghmeGhcVersion = v
                    , ghmeContinueOnError =
                           previewGHC cfgHeadHackage compiler
                        || maybeGHC False (`C.withinRange` cfgAllowFailures) compiler
                    }
                | compiler@(GHC v) <- reverse $ toList versions
                ]
            }
        }
  where
    Auxiliary {..} = auxiliary config prj jobs

    -- step primitives
    githubRun' :: String -> Map.Map String String ->  ShM () -> ListBuilder (Either ShError GitHubStep) ()
    githubRun' name env shm = item $ do
        shs <- runSh shm
        return $ GitHubStep name $ Left $ GitHubRun shs env

    githubRun :: String -> ShM () -> ListBuilder (Either ShError GitHubStep) ()
    githubRun name = githubRun' name mempty

    githubUses :: String -> String -> [(String, String)] -> ListBuilder (Either ShError GitHubStep) ()
    githubUses name action with = item $ return $
        GitHubStep name $ Right $ GitHubUses action (Map.fromList with)

    -- shell primitives
    echo_to' :: FilePath -> String -> String
    echo_to' fp s = "echo " ++ show s ++ " >> " ++ fp

    echo_to :: FilePath -> String -> ShM ()
    echo_to fp s = sh $ echo_to' fp s

    echo_if_to :: CompilerRange -> FilePath -> String -> ShM ()
    echo_if_to range fp s = sh_if range $ echo_to' fp s

    change_dir_if :: CompilerRange -> String -> ShM ()
    change_dir_if range dir = sh_if range ("cd " ++ dir ++ " || false")

    tell_env' :: String -> String -> String
    tell_env' k v = "echo " ++ show (k ++ "=" ++ v) ++ " >> $GITHUB_ENV"

    tell_env :: String -> String -> ShM ()
    tell_env k v = sh $ tell_env' k v

    if_then_else :: CompilerRange -> String -> String -> ShM ()
    if_then_else range con alt
        | all (`compilerWithinRange` range) versions       = sh con
        | not $ any (`compilerWithinRange` range) versions = sh alt
        | otherwise = sh $ unwords
        [ "if ["
        , compilerVersionArithPredicate versions range
        , "-ne 0 ]"
        , "; then"
        , con
        , ";"
        , "else"
        , alt
        , ";"
        , "fi"
        ]

    sh_if :: CompilerRange -> String -> ShM ()
    sh_if range con
        | all (`compilerWithinRange` range) versions       = sh con
        | not $ any (`compilerWithinRange` range) versions = pure ()
        | otherwise = sh $ unwords
        [ "if ["
        , compilerVersionArithPredicate versions range
        , "-ne 0 ]"
        , "; then"
        , con
        , ";"
        , "fi"
        ]

    -- Needed to work around haskell/cabal#6214
    withHaddock :: String
    withHaddock = "--with-haddock $HADDOCK"

cat :: FilePath -> String -> ShM ()
cat path contents = sh $ concat
    [ "cat >> " ++ path ++ " <<EOF\n"
    , contents
    , "EOF"
    ]
