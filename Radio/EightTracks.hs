{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- | Module of http://8tracks.com
module Radio.EightTracks where

import           Control.Monad (forM_, liftM)
import           Data.Aeson
import           Data.Aeson.Types (defaultOptions, Options(..))
import qualified Data.ByteString.Char8 as C
import           Data.Maybe (fromJust)
import           Data.Yaml hiding (decode)
import           Data.CaseInsensitive (mk)
import           Data.Conduit (($$+-))
import           Data.Conduit.Attoparsec (sinkParser)
import           GHC.Generics (Generic)
import           Network.HTTP.Types 
import           Network.HTTP.Conduit
import           Prelude hiding (id)
import           System.Console.ANSI
import           System.Directory (doesFileExist)

import Radio
import qualified Radio.EightTracks.Explore as Exp
import qualified Radio.EightTracks.User as U


apiKey :: String
apiKey = "1de30eb2b8fe85b1740cfbee3fdbb928e2c7249b"

verHdr, keyHdr :: Header
verHdr = (mk "X-Api-Version", "3")
keyHdr = (mk "X-Api-Key", C.pack apiKey)

type Param a = Radio.Param EightTracks

data PlaySession = PlaySession
    { play_token            :: String
    , status                :: String
    , errors                :: Maybe String
    , notices               :: Maybe String
    , api_version           :: Int
    } deriving (Show, Generic)

data EightTracks = EightTracks 
    { id                    :: Int
    , track_file_stream_url :: String
    , name                  :: String
    , performer             :: String
    , release_name          :: String
    , url                   :: String
    } deriving (Show, Generic)

data MixSet = MixSet
    { at_beginning          :: Bool
    , at_last_track         :: Bool
    , at_end                :: Bool
    , skip_allowed          :: Bool
    , track                 :: EightTracks
    } deriving (Show, Generic)

data MixResponse = MixResponse
    { mix_set               :: MixSet
    , mix_status            :: String
    } deriving (Show, Generic)

instance FromJSON PlaySession
instance FromJSON EightTracks
instance FromJSON MixSet

instance FromJSON MixResponse where
    parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 4 }

instance Radio.Radio EightTracks where
    data Param EightTracks = Token
        { userToken     :: String
        , userName      :: String
        , playToken     :: Int
        , mixId         :: Int
        } deriving (Show, Generic)

    parsePlaylist val =
        case fromJSON val of
            Success s -> [track $ mix_set s]
            Error err -> error $ "Parse playlist failed: " ++ show err

    getPlaylist tok = do
        let rurl = "http://8tracks.com/sets/" ++ (show $ playToken tok)  ++ "/next.json"
            query = [ ("mix_id", C.pack $ show $ mixId tok) ]

        initReq <- parseUrl rurl
        let req = initReq { requestHeaders = [verHdr, keyHdr] 
                          , queryString = renderSimpleQuery False query }
        withManager $ \manager -> do
            res <- http req manager
            liftM Radio.parsePlaylist (responseBody res $$+- sinkParser json)

    songUrl _ x = return $ track_file_stream_url x

    songMeta x = Radio.SongMeta (performer x) (release_name x) (name x)

    tagged _ = False
    
    playable _ = False

    reportRequired _ = True

    -- At 30 seconds, report song played
    report tok x = do
        initReq <- parseUrl rurl
        let usrHdr = (mk "X-User-Token", C.pack $ userToken tok)
            req = initReq { requestHeaders = [verHdr, keyHdr, usrHdr] 
                          , queryString = renderSimpleQuery False query }
        res <- withManager $ \manager -> httpLbs req manager
        print $ responseBody res
      where
        rurl = "http://8tracks.com/sets/" ++ (show $ playToken tok) ++ "/report.json"
        query = [ ("track_id", C.pack $ show $ id x)
                , ("mix_id", C.pack $ show $ mixId tok) ]

instance FromJSON (Radio.Param EightTracks)
instance ToJSON (Radio.Param EightTracks)

instance NeedLogin EightTracks where
    createSession strMixId email pwd = do
        initReq <- parseUrl rurl
        let req = initReq { method = "POST"
                          , queryString = renderSimpleQuery False query
                          , requestHeaders = [verHdr] }
        res <- withManager $ \manager -> httpLbs req manager
        case eitherDecode $ responseBody res of
            Right r  -> do
                pTok <- newPlayToken
                return $ Just $ Token (U.user_token $ U.user r)
                                      (U.login $ U.user r) pTok mId
            Left err -> print err >> return Nothing
      where
        rurl = "http://8tracks.com/sessions.json"
        query = [ ("login", C.pack email), ("password", C.pack pwd) ]
        mId = read strMixId :: Int

    data Config EightTracks = Config { eight :: Radio.Param EightTracks } deriving Generic

    mkConfig tok = Config tok

    readToken mid = do
        home <- Radio.getLordDir
        let yml = home ++ "/lord.yml"
        exist <- doesFileExist yml
        if exist
           then do
                conf <- decodeFile yml
                case conf of
                    Nothing -> error $ "Invalid YAML file: " ++ show conf
                    Just c -> 
                        case fromJSON c of
                            Success tok -> return $ Just $ (eight tok) { mixId = read mid }
                            Error err -> do
                                print $ "Parse token failed: " ++ show err
                                return Nothing
           else return Nothing

instance FromJSON (Radio.Config EightTracks)
instance ToJSON (Radio.Config EightTracks)

newPlayToken :: IO Int
newPlayToken = do
    res <- simpleHttp rurl
    let ses = fromJust (decode res :: Maybe PlaySession)
    return $ read $ play_token ses
  where
    rurl = "http://8tracks.com/sets/new.json?api_version=3&api_key=" ++ apiKey 

search :: String -> IO [Exp.Mix]
search [] = return []
search key = search' rurl
  where 
    rurl = "http://8tracks.com/mix_sets/keyword:" ++ key ++ ".json?include=mixes"

search' :: String -> IO [Exp.Mix]
search' rurl = do
    initReq <- parseUrl rurl
    let req = initReq { requestHeaders = [verHdr, keyHdr] }
    val <- withManager $ \manager -> do
        res <- http req manager
        responseBody res $$+- sinkParser json

    case fromJSON val of
        Success v -> return $ Exp.mixes $ Exp.mix_set v
        Error err -> putStrLn err >> return []

pprMixes :: [Exp.Mix] -> IO ()
pprMixes mixes =
    forM_ mixes (\m -> do
        setSGR [SetConsoleIntensity BoldIntensity]
        putStr $ "* " ++ Exp.name m 
        setSGR [SetColor Foreground Vivid Green]
        putStrLn $ " id=" ++ show (Exp.id m)
        setSGR [Reset]
        putStrLn $ "    Description: " ++ Exp.description m
        putStrLn $ "    Tags: " ++ Exp.tag_list_cache m
        putStrLn ""
        )
