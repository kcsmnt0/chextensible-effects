module Script.NegamaxVsIMCSOpponent where

import Agent.AlphaBetaNegamax as Negamax
import Agent.IMCSOpponent as IMCSOpponent
import Chess
import Control.Monad
import Control.Monad.Freer
import Control.Monad.Freer.Console
import Control.Monad.Freer.Exception
import Control.Monad.Freer.Socket
import Control.Monad.Freer.State
import Control.Monad.Loops
import Data.Maybe
import Grid.Array
import IMCS
import Text.Read

clientAgent = Negamax.agent @ArrayBoard
serverAgent = IMCSOpponent.agent

data Initiation = Offer | Accept

readInitiation :: String -> Maybe Initiation
readInitiation "offer" = Just Offer
readInitiation "accept" = Just Accept
readInitiation _ = Nothing

-- Connect to the server, let the user offer or accept a game, and run a local game between a local negamax agent and
-- an agent communicating with the IMCS server.
runNegamaxVsIMCSOpponentIO :: IO ()
runNegamaxVsIMCSOpponentIO = runM $ imcsOpponentRunIO_ $ do
  socketRecvLine >>= ensureResponseCode 100

  user <- prompt "username"
  pass <- prompt "password"
  me user pass

  init <- untilJust (readInitiation <$> prompt "offer/accept")
  player <- case init of
    Offer -> do
      p <- untilJust (readPlayer . head <$> prompt "player (W/B)")
      offer p
      return p

    Accept -> accept <=< untilJust $ do
      games <- list
      consoleWrite $ unlines $ zipWith (++) [show x ++ ": " | x <- [0..]] (map show games)
      fmap readMaybe (send getLine) >>= \case
        Just i | 0 <= i && i < length games -> return $ Just $ gameID (games !! i)
        _ -> return Nothing

  case player of
    White -> negamaxRunIO @ArrayBoard @White $ void $ playGame (clientAgent WHITE) (serverAgent BLACK)
    Black -> negamaxRunIO @ArrayBoard @Black $ void $ playGame (serverAgent WHITE) (clientAgent BLACK)
