-----------------------------------------------------------------------------
-- |
-- Module      :  Hackage.Install
-- Copyright   :  (c) David Himmelstrup 2005
-- License     :  BSD-like
--
-- Maintainer  :  lemmih@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- High level interface to package installation.
-----------------------------------------------------------------------------
module Hackage.List (
  list
  ) where

import Data.List (nub, sortBy, groupBy)
import Data.Monoid (Monoid(mconcat))

import Distribution.Package (PackageIdentifier(..), Package(..))
import Distribution.PackageDescription
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Version (showVersion)
import Distribution.Verbosity (Verbosity)

import qualified Hackage.IndexUtils as IndexUtils
import Hackage.Types (PkgInfo(..), Repo)
import Distribution.Simple.Utils (equating, comparing, intercalate, lowercase)

-- |Show information about packages
list :: Verbosity -> [Repo] -> [String] -> IO ()
list verbosity repos pats = do
    indexes <- mapM (IndexUtils.readRepoIndex verbosity) repos
    let index = mconcat indexes
        pkgs | null pats = PackageIndex.allPackages index
             | otherwise =
                 concatMap (PackageIndex.searchByNameSubstring index) pats
    putStrLn
      . unlines
      . map showPkgVersions
      . groupBy (equating (pkgName . packageId))
      . sortBy (comparing nameAndVersion)
      $ pkgs

  where
    nameAndVersion p = (lowercase name, name, version)
        where name = pkgName (packageId p)
              version = pkgVersion (packageId p)


showPkgVersions :: [PkgInfo] -> String
showPkgVersions pkgs =
    padTo 35 $ pkgName (packageId pkg)
            ++ " ["
            ++ intercalate ", " (map showVersion versions)
            ++ "] "
    ++ synopsis (packageDescription (pkgDesc pkg))
  where
    pkg = last pkgs
    versions = nub (map (pkgVersion . packageId) pkgs)
    padTo n s = s ++ (replicate (n - length s) ' ')