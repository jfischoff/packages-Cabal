{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -cpp #-}
{-# OPTIONS_NHC98 -cpp #-}
{-# OPTIONS_JHC -fcpp #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.PackageDescription.QA
-- Copyright   :  Lennart Kolmodin 2008
--
-- Maintainer  :  Lennart Kolmodin <kolmodin@gentoo.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Quality Assurance for package descriptions.
-- 
-- This module provides functionality to check for common mistakes.

{- All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.PackageDescription.QA (
        cabalVersion,
        sanityCheckPackage,
        
        -- * Quality Assurance
        qaCheckPackage,
        QANotice(..)
  ) where

import Data.Maybe (isNothing, catMaybes)
import Control.Monad (when,unless)
import System.Directory (doesFileExist)

import Distribution.PackageDescription.Types
import Distribution.PackageDescription.Parse
import Distribution.Compiler(CompilerFlavor(..))
import Distribution.License (License(..))

import Text.PrettyPrint.HughesPJ
import Distribution.Version (Version(..), withinRange, showVersionRange)
import Distribution.Package (PackageIdentifier(..))
import System.FilePath (takeExtension)

-- We only get our own version number when we're building with ourselves
cabalVersion :: Version
#ifdef CABAL_VERSION
cabalVersion = Version [CABAL_VERSION] []
#else
cabalVersion = error "Cabal was not bootstrapped correctly"
#endif

-- ------------------------------------------------------------
-- * Sanity Checking
-- ------------------------------------------------------------

-- |Sanity check this description file.

-- FIX: add a sanity check for missing haskell files? That's why its
-- in the IO monad.

sanityCheckPackage :: PackageDescription -> IO ([String] -- Warnings
                                               ,[String])-- Errors
sanityCheckPackage pkg_descr = do
    let libSane   = sanityCheckLib (library pkg_descr)
        nothingToDo = checkSanity
                        (null (executables pkg_descr) 
                         && isNothing (library pkg_descr))
                        "No executables and no library found. Nothing to do."
        noModules = checkSanity (hasMods pkg_descr)
                      "No exposed modules or executables in this package."
        goodCabal = let v = (descCabalVersion pkg_descr)
                    in checkSanity (not $ cabalVersion  `withinRange` v)
                           ("This package requires Cabal version: " 
                              ++ (showVersionRange v) ++ ".")
        noBuildType = checkSanity (isNothing $ buildType pkg_descr)
	                "No 'build-type' specified. If possible use 'build-type: Simple'"
        lf = licenseFile pkg_descr
        
    noLicense <- checkSanityIO (licenseDoesNotExist lf)
                   ("License file " ++ lf ++ " does not exist.")

    return $ ( catMaybes [nothingToDo, noModules, noBuildType, noLicense],
               catMaybes (libSane:goodCabal: checkMissingFields pkg_descr
                 ++ map sanityCheckExe (executables pkg_descr)) )

toMaybe :: Bool -> a -> Maybe a
toMaybe b x = if b then Just x else Nothing

checkMissingFields :: PackageDescription -> [Maybe String]
checkMissingFields pkg_descr = 
    [missingField (pkgName . package)    reqNameName
    ,missingField (versionBranch .pkgVersion .package) reqNameVersion
    ]
    where missingField :: (PackageDescription -> [a]) -- Field accessor
                       -> String -- Name of field
                       -> Maybe String -- error message
          missingField f n
              = toMaybe (null (f pkg_descr)) ("Missing field: " ++ n)

sanityCheckLib :: Maybe Library -> Maybe String
sanityCheckLib ml = do
    l <- ml
    toMaybe (buildable (libBuildInfo l) && null (exposedModules l)) $
       "A library was specified, but no exposed modules list has been given.\n"
       ++ "Fields of the library section:\n"
       ++ (render $ nest 4 $ ppFields l libFieldDescrs )
   

sanityCheckExe :: Executable -> Maybe String
sanityCheckExe exe
   | null (modulePath exe)
   = Just ("No 'Main-Is' field found for executable " ++ exeName exe
                  ++ "Fields of the executable section:\n"
                  ++ (render $ nest 4 $ ppFields exe executableFieldDescrs))
   | ext `notElem` [".hs", ".lhs"]
   = Just ("The 'Main-Is' field must specify a '.hs' or '.lhs' file\n"
         ++"    (even if it is generated by a preprocessor).")
   | otherwise = Nothing
   where ext = takeExtension (modulePath exe)

checkSanity :: Bool -> String -> Maybe String
checkSanity = toMaybe

checkSanityIO :: IO Bool -> String -> IO (Maybe String)
checkSanityIO test str = do b <- test
                            return $ toMaybe b str

hasMods :: PackageDescription -> Bool
hasMods pkg_descr =
   null (executables pkg_descr) &&
      maybe True (null . exposedModules) (library pkg_descr)

licenseDoesNotExist :: FilePath -> IO Bool
licenseDoesNotExist lf = do
    b <- doesFileExist lf
    return $ not (null lf || b)

-- ------------------------------------------------------------
-- * Quality Assurance
-- ------------------------------------------------------------

-- TODO: give hints about old extentions. see Simple.GHC, reverse mapping
-- TODO: and allmost ghc -X flags should be extensions
-- TODO: Once we implement striping (ticket #88) we should also reject
--       ghc-options: -optl-Wl,-s.
-- TODO: keep an eye on #190 and implement when/if it's closed.
-- warn for ghc-options: -fvia-C when ForeignFunctionInterface is set
-- http://hackage.haskell.org/trac/hackage/ticket/190

data QANotice
    = QAWarning { qaMessage :: String }
    | QAFailure { qaMessage :: String }

instance Show QANotice where
    show notice = qaMessage notice

-- |Quality Assurance for package descriptions.
qaCheckPackage :: PackageDescription -> IO [QANotice]
qaCheckPackage pkg_descr = fmap fst . runQA $ do
    ghcSpecific pkg_descr
    cabalFormat pkg_descr

    checkLicense pkg_descr

cabalFormat :: PackageDescription -> QA ()
cabalFormat pkg_descr = do
    when (isNothing (buildType pkg_descr)) $
        critical "No 'build-type' specified."
    when (null (category pkg_descr)) $
        warn "No 'category' field."
    when (null (description pkg_descr)) $
        warn "No 'description' field."
    when (null (maintainer pkg_descr)) $
        warn "No 'maintainer' field."
    when (null (synopsis pkg_descr)) $
        warn "No 'synopsis' field."
    when (length (synopsis pkg_descr) >= 80) $
        warn "The 'synopsis' field is rather long (max 80 chars is recommended)"


ghcSpecific :: PackageDescription -> QA ()
ghcSpecific pkg_descr = do
    let has_WerrorWall = flip any ghc_options $ \opts ->
                               "-Werror" `elem` opts
                           && ("-Wall"   `elem` opts || "-W" `elem` opts)
        has_Werror     = any (\opts -> "-Werror" `elem` opts) ghc_options
    when has_WerrorWall $
        critical $ "'ghc-options: -Wall -Werror' makes the package "
                 ++ "very easy to break with future GHC versions."
    when (not has_WerrorWall && has_Werror) $
        warn $ "'ghc-options: -Werror' makes the package easy to "
            ++ "break with future GHC versions."

    ghcFail "-fasm" $
        "The -fasm flag is unnecessary and breaks on all "
        ++ "arches except for x86, x86-64 and ppc."

    ghcFail "-O" $
        "-O is not needed. Cabal automatically adds the '-O' flag.\n"
        ++ "    Setting it yourself interferes with the --disable-optimization flag."

    ghcWarn "-O2" $
        "-O2 is rarely needed. Check that it is giving a real benefit\n"
        ++ "    and not just imposing longer compile times on your users."

    -- most important at this stage to get the framework right
    when (any (`elem` all_ghc_options) ["-ffi", "-fffi"]) $
    	critical $ "Instead of using -ffi or -fffi, use 'extensions: "
    		 ++"ForeignFunctionInterface'"

    where
    ghc_options = [ strs | bi <- allBuildInfo pkg_descr
                         , (GHC, strs) <- options bi ]
    all_ghc_options = concat ghc_options


    ghcWarn :: String -> String -> QA ()
    ghcWarn flag msg =
        when (flag `elem` all_ghc_options) $
            warn ("ghc-options: " ++ msg)

    ghcFail :: String -> String -> QA ()
    ghcFail flag msg =
        when (flag `elem` all_ghc_options) $
            critical ("ghc-options: " ++ msg)


checkLicense :: PackageDescription -> QA ()
checkLicense pkg
    | license pkg == AllRightsReserved
    = critical "The 'license' field is missing or specified as AllRightsReserved"

    | null (licenseFile pkg)
    = warn "A 'license-file' is not specified"

    | otherwise = do
        exists <- io $ doesFileExist file
        unless exists $
            critical $ "The 'license-file' field refers to the file \"" ++ file
                     ++ "\" which does not exist."
        where file = licenseFile pkg


-- the WriterT monad over IO
data QA a = QA { runQA :: IO ([QANotice], a) }

instance Monad QA where
    a >>= mb = QA $ do
        (warnings, x) <- runQA a
        (warnings', x') <- runQA (mb x)
        return (warnings ++ warnings', x')
    return x = QA $ return ([], x)

qa :: QANotice -> QA ()
qa notice = QA $ return ([notice], ())

warn :: String -> QA ()
warn = qa . QAWarning

critical :: String -> QA ()
critical = qa . QAFailure

io :: IO a -> QA a
io action = QA $ do
    x <- action
    return ([], x)