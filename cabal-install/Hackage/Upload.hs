-- This is a quick hack for uploading packages to Hackage.
-- See http://hackage.haskell.org/trac/hackage/wiki/CabalUpload

module Hackage.Upload (upload) where

import Hackage.Setup (UploadFlags(..))
import Distribution.Simple.Utils (debug, notice)
import Distribution.Simple.Setup (toFlag, fromFlag, flagToMaybe)

import Network.Browser (BrowserAction, browse, request, 
                        Authority(..), addAuthority,
                        setOutHandler, setErrHandler)
import Network.HTTP (Header(..), HeaderName(..), Request(..),
                     RequestMethod(..), Response(..))
import Network.URI (URI, parseURI)

import Control.Monad    (MonadPlus(mplus))
import Data.Char        (intToDigit)
import Numeric          (showHex)
import System.Directory (doesFileExist, getAppUserDataDirectory)
import System.IO        (hFlush, stdout)
import System.Random    (randomRIO)
import System.FilePath  ((</>))

type Username = String
type Password = String


uploadURI :: URI
Just uploadURI = parseURI "http://hackage.haskell.org/cgi-bin/hackage-scripts/protected/upload-pkg"

checkURI :: URI
Just checkURI = parseURI "http://hackage.haskell.org/cgi-bin/hackage-scripts/check-pkg"



upload :: UploadFlags -> [FilePath] -> IO ()
upload flags paths = do
          flags' <- if needsAuth flags then getAuth flags else return flags
          mapM_ (handlePackage flags') paths

handlePackage :: UploadFlags -> FilePath -> IO ()
handlePackage flags path =
  do (uri, auth) <- if fromFlag (uploadCheck flags)
                         then do notice verbosity $ "Checking " ++ path ++ "... "
                                 return (checkURI, return ())
                         else do notice verbosity $ "Uploading " ++ path ++ "... "
                                 return (uploadURI, 
                                         setAuth uploadURI 
                                                 (fromFlag (uploadUsername flags))
                                                 (fromFlag (uploadPassword flags)))
     req <- mkRequest uri path
     debug verbosity $ "\n" ++ show req
     (_,resp) <- browse (setErrHandler ignoreMsg 
                      >> setOutHandler ignoreMsg 
                      >> auth 
                      >> request req)
     debug verbosity $ show resp
     case rspCode resp of
       (2,0,0) -> do notice verbosity "OK"
       (x,y,z) -> do notice verbosity $ "ERROR: " ++ path ++ ": " 
                                     ++ map intToDigit [x,y,z] ++ " "
                                     ++ rspReason resp
                     debug verbosity $ rspBody resp
  where verbosity = fromFlag (uploadVerbosity flags)

needsAuth :: UploadFlags -> Bool
needsAuth = not . fromFlag . uploadCheck

setAuth :: URI -> Username -> Password -> BrowserAction ()
setAuth uri user pwd = 
    addAuthority $ AuthBasic { auRealm    = "Hackage",
                               auUsername = user,
                               auPassword = pwd,
                               auSite     = uri }

getAuth :: UploadFlags -> IO UploadFlags
getAuth flags = 
    do (mu, mp) <- readAuthFile
       u <- case flagToMaybe (uploadUsername flags) `mplus` mu of
              Just u  -> return u
              Nothing -> promptUsername
       p <- case flagToMaybe (uploadPassword flags) `mplus` mp of
              Just p  -> return p
              Nothing -> promptPassword
       return $ flags { uploadUsername = toFlag u,
                        uploadPassword = toFlag p }
       
promptUsername :: IO Username
promptUsername = 
    do putStr "Hackage username: "
       hFlush stdout
       getLine

promptPassword :: IO Password
promptPassword = 
    do putStr "Hackage password: "
       hFlush stdout
       getLine

authFile :: IO FilePath
authFile = do dir <- getAppUserDataDirectory "cabal-upload"
              return $ dir </> "auth"

readAuthFile :: IO (Maybe Username, Maybe Password)
readAuthFile = 
    do file <- authFile
       e <- doesFileExist file
       if e then do s <- readFile file
                    let (u,p) = read s
                    return (Just u, Just p)
            else return (Nothing, Nothing)

ignoreMsg :: String -> IO ()
ignoreMsg _ = return ()

mkRequest :: URI -> FilePath -> IO Request
mkRequest uri path = 
    do pkg <- readFile path
       boundary <- genBoundary
       let body = printMultiPart boundary (mkFormData path pkg)
       return $ Request {
                         rqURI = uri,
                         rqMethod = POST,
                         rqHeaders = [Header HdrContentType ("multipart/form-data; boundary="++boundary),
                                      Header HdrContentLength (show (length body)),
                                      Header HdrAccept ("text/plain")],
                         rqBody = body
                        }

genBoundary :: IO String
genBoundary = do i <- randomRIO (0x10000000000000,0xFFFFFFFFFFFFFF) :: IO Integer
                 return $ showHex i ""

mkFormData :: FilePath -> String -> [BodyPart]
mkFormData path pkg = 
    -- yes, web browsers are that stupid (re quoting)
    [BodyPart [Header hdrContentDisposition ("form-data; name=package; filename=\""++path++"\""),
               Header HdrContentType "application/x-gzip"] 
     pkg]

hdrContentDisposition :: HeaderName
hdrContentDisposition = HdrCustom "Content-disposition"

-- * Multipart, partly stolen from the cgi package.

data BodyPart = BodyPart [Header] String

printMultiPart :: String -> [BodyPart] -> String
printMultiPart boundary xs = 
    concatMap (printBodyPart boundary) xs ++ crlf ++ "--" ++ boundary ++ "--" ++ crlf

printBodyPart :: String -> BodyPart -> String
printBodyPart boundary (BodyPart hs c) = crlf ++ "--" ++ boundary ++ crlf ++ concatMap show hs ++ crlf ++ c

crlf :: String
crlf = "\r\n"