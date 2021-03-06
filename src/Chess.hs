-- todo: organization
module Chess where

import Control.Monad
import Control.Monad.Freer
import Control.Monad.Loops
import Data.Char
import Data.Maybe
import Grid
import Text.Read

data Player = Black | White deriving (Eq, Ord)
data Shape = Pawn | Knight | Bishop | Rook | Queen | King deriving (Eq, Ord, Enum)
data Piece = Piece { owner :: Player, shape :: Shape } deriving (Eq, Ord)

allPieces :: [Piece]
allPieces = Piece <$> [Black, White] <*> [Pawn .. King]

-- todo: find somewhere else to put this or maybe find it in a library
type family (++) as bs where
  '[] ++ bs = bs
  (a:as) ++ bs = a : (as ++ bs)

type Board = Grid (Maybe Piece)

-- Each piece type has a mask associated with it that indicates all the spaces it could potentially move to if the
-- conditions were right. A Condition represents which condition needs to hold.
data Condition = Empty | Occupied | Whatever deriving (Show, Eq)

-- A trajectory is just some subset of the spaces a piece can reach: it can either jump to some offset, or slide across
-- some ray until it hits the edge of the board or another piece.
data Trajectory = Offset (Int,Int) | Ray (Int,Int) deriving (Show, Eq)

-- A PotentialMove is a set of spaces that can be moved to under some condition.
data PotentialMove = PotentialMove { condition :: Condition, trajectory :: Trajectory } deriving (Show, Eq)

type Move = (Index, Index)

-- "Migrate" just means "did not capture". (Is there a chess word for that?)
data MoveResult = Capture Shape | Migrate deriving (Show, Eq)

data MoveRecord = MoveRecord { result :: MoveResult, move :: Move } deriving (Show, Eq)

data TurnOutcome = Move Move | Win Move | Tie | Lose deriving (Show, Eq) -- todo: Tie needs a last move too

data GameOutcome = Victor Player | Draw deriving (Show, Eq)

data Rank
  = Rank Int -- board score
  | Lost Int -- turns left
  | Won  Int -- turns left
  deriving (Show, Eq)

-- An Agent is parameterized over a list of effects.  Each agent maintains its own state within the effectful context
-- that it runs in, so there's no shared board state to pass around.
-- "act" prompts the agent to take its turn and return the result.
-- "observe" tells the agent the result of its opponent's move so that it can react effectfully.
data Agent es = Agent
  { act :: forall effs. Members es effs => Eff effs TurnOutcome
  , observe :: forall effs. Members es effs => Move -> Eff effs ()
  }

-- Some of my type-level shenanigans depend on Player values lifted to types, but I need them at the term level
-- sometimes too, so "PlayerSing p" is a singleton type that provides a type-level Player and can be cased over.
data PlayerSing (p :: Player) where -- todo: the singletons library takes care of all this stuff
  WHITE :: PlayerSing White
  BLACK :: PlayerSing Black

-- todo: dedicated module for IMCS-format reading and showing
instance Show Player where
  show White = "W"
  show Black = "B"

instance Show (PlayerSing p) where
  show WHITE = show White
  show BLACK = show Black

instance Show Shape where
  show Pawn = "P"
  show Knight = "N"
  show Bishop = "B"
  show Rook = "R"
  show Queen = "Q"
  show King = "K"

instance Show Piece where
  show (Piece White s) = show s
  show (Piece Black s) = map toLower $ show s

instance Ord Rank where
  compare (Rank x) (Rank y) = compare x y
  compare (Rank _) (Won _) = LT
  compare (Rank _) (Lost _) = GT
  compare (Won x) (Won y) = compare x y -- winning earlier (i.e. with more turns left) is better than winning later
  compare (Won _) _ = GT
  compare (Lost x) (Lost y) = compare (-x) (-y) -- losing later is better than losing earlier
  compare (Lost _) _ = LT

negateRank :: Rank -> Rank
negateRank (Rank x) = Rank $ negate x
negateRank (Lost x) = (Won x)
negateRank (Won x) = (Lost x)

readPlayer :: Char -> Maybe Player
readPlayer 'W' = Just White
readPlayer 'B' = Just Black
readPlayer _ = Nothing

readColumn :: Char -> Maybe Int
readColumn c = if 'a' <= c && c <= 'e' then Just (ord c - ord 'a') else Nothing

-- The internal board representation is mirrored vertically versus the output format, so the row indices are
-- mirrored here.
readRow :: Char -> Maybe Int
readRow c = do i <- readMaybe (c:""); if 1 <= i && i <= 6 then Just (6-i) else Nothing

readMove :: String -> Maybe Move
readMove [readColumn -> Just x, readRow -> Just y, '-', readColumn -> Just x', readRow -> Just y'] = Just ((x,y), (x',y'))
readMove _ = Nothing

showColumn :: Int -> Char
showColumn = chr . (ord 'a' +)

showRow :: Int -> Char
showRow = head . show . (6 -)

showMove :: Move -> String
showMove ((x,y), (x',y')) = [showColumn x, showRow y, '-', showColumn x', showRow y']

showBoard :: Board b => b -> String
showBoard b = unlines $ concat
  [ map (("  " ++) . flip map [0..w-1]) [chr . (ord 'a' +), const ' ']
  , [ concat
      [ show (h-y)
      , " "
      , concat [maybe "." show (b!(x,y)) | x <- [0..w-1]]
      , " "
      , show (h-y)
      ]
    | y <- [0..h-1]
    ]
  , map (("  " ++) . flip map [0..w-1]) [const ' ', chr . (ord 'a' +)]
  ]
  where
    (w,h) = size b

playerSing :: PlayerSing p -> Player
playerSing WHITE = White
playerSing BLACK = Black

opponent :: Player -> Player
opponent Black = White
opponent White = Black

type family Opponent (p :: Player) where
  Opponent White = Black
  Opponent Black = White

opponentSing :: PlayerSing p -> PlayerSing (Opponent p)
opponentSing WHITE = BLACK
opponentSing BLACK = WHITE

pieces :: Board b => Player -> b -> [(Index, Shape)]
pieces p b = [(i, shape x) | (i, Just x) <- assocs b, owner x == p]

pieceValue :: Shape -> Int
pieceValue Pawn = 10
pieceValue Bishop = 30
pieceValue Knight = 30
pieceValue Rook = 50
pieceValue Queen = 90
pieceValue King = 0

pieceScore :: Index -> Piece -> Int
pieceScore (x,y) (Piece p Pawn) = pieceValue Pawn + case p of White -> 5-y; Black -> y -- prioritize pawn advancement
pieceScore _ (Piece _ s) = pieceValue s

boardScore :: Board b => Player -> b -> Int
boardScore p b = sum [(if p == p' then 1 else -1) * pieceScore i pc | (i, Just pc@(Piece p' s)) <- assocs b]

shift :: Index -> Index -> Index
shift (x,y) (x',y') = (x+x',y+y')

rotate :: Trajectory -> Trajectory
rotate (Offset (x,y)) = Offset (y,-x)
rotate (Ray (x,y)) = Ray (y,-x)

rotations :: Trajectory -> [Trajectory]
rotations = take 4 . iterate rotate

down :: Trajectory
down = Ray (0,1)

downRight :: Trajectory
downRight = Ray (1,1)

-- The rook and queen can move along the horizontal and vertical axes.
axes :: [Trajectory]
axes = rotations down

-- The biship and queen can move along the axes rotated by 45 degrees.
diagonals :: [Trajectory]
diagonals = rotations downRight

at p = PotentialMove p . Offset

-- The mask of a piece is the set of all potential moves it has available.
mask :: Piece -> [PotentialMove]
mask (Piece Black Pawn) = [Empty `at` (0, 1), Occupied `at` (-1, 1), Occupied `at` (1, 1)]
mask (Piece White Pawn) = [Empty `at` (0,-1), Occupied `at` (-1,-1), Occupied `at` (1,-1)]
mask (Piece _ Knight) = map (Whatever `at`) [(2,1), (2,-1), (-2,1), (-2,-1), (1,2), (1,-2), (-1,2), (-1,-2)]
mask (Piece _ Bishop) = map (Empty `at`) [(0,1), (0,-1), (1,0), (-1,0)] ++ map (PotentialMove Whatever) diagonals
mask (Piece _ Rook) = map (PotentialMove Whatever) axes
mask (Piece _ Queen) = map (PotentialMove Whatever) (axes ++ diagonals)
mask (Piece _ King) = map (Whatever `at`) [(1,-1), (1,0), (1,1), (0,-1), (0,1), (-1,-1), (-1,0), (-1,1)]

-- todo: put this somewhere
takeWhile1 :: (a -> Bool) -> [a] -> [a]
takeWhile1 p [] = []
takeWhile1 p (x:xs) = x : if p x then takeWhile1 p xs else []

-- The cells along a trajectory that a piece can legally reach on the given board.
reachable :: Board b => b -> Index -> Trajectory -> [Index]
reachable b i (Offset j) = let i' = shift i j in [i' | i' `within` b]
reachable b i (Ray j) = takeWhile1 (isNothing . (b!)) $ takeWhile (`within` b) $ tail $ iterate (shift j) i

moveResult :: Player -> Condition -> Maybe Piece -> Maybe MoveResult
moveResult c Empty Nothing = Just Migrate
moveResult c Occupied (Just (Piece c' s)) | (c' == opponent c) = Just $ Capture s
moveResult c Whatever Nothing = Just Migrate
moveResult c Whatever (Just (Piece c' s)) | (c' == opponent c) = Just $ Capture s
moveResult _ _ _ = Nothing

-- All of the legal moves for a piece at a given index (without checking that it's actually there).
pieceMoves :: Board b => b -> Index -> Piece -> [MoveRecord]
pieceMoves b i p = do
  PotentialMove m t <- mask p
  i' <- reachable b i t
  e <- maybeToList $ moveResult (owner p) m (b!i')
  return $ MoveRecord e (i, i')

-- All the legal moves that the player can make.
moves :: Board b => Player -> b -> [MoveRecord]
moves p b = [m | (i,s) <- pieces p b, m <- pieceMoves b i (Piece p s)]

lost :: Board b => Player -> b -> Bool
lost p b = not (any (maybe False (\(Piece p' s) -> s == King && p' == p)) (elems b)) || null (moves p b)

won :: Board b => Player -> b -> Bool
won = lost . opponent

-- Update a board with the result of a move.
makeMove :: Board b => Move -> b -> b
makeMove (i, j) b = replace i Nothing (replace j pc' b)
  where
    pc' = case b!i of
      Just (Piece p Pawn) | (p == White && snd j == 0) || (p == Black && snd j == 5) -> Just (Piece p Queen)
      pc -> pc

-- Take a pair of indices and return a strongly-typed move if they represent a legal movement on the board.
maybeMove :: Board b => b -> Move -> Maybe MoveRecord
maybeMove b (i, j) = do
  p <- b!i
  let p' = b!j
  -- todo: this is definitely more complicated than it needs to be
  listToMaybe $ do
    m@(MoveRecord e (i,j')) <- pieceMoves b i p
    guard (j == j')
    guard $ case e of
      Migrate -> isNothing p'
      Capture _ -> isJust p'
    return m

-- The board position at the start of the game.
initialBoard :: Board b => b
initialBoard = foldr1 (.) [replace i (Just x) | (i,x) <- positions] (empty (5,6) Nothing)
  where
    positions = backRow Black 0 [0..4] ++ pawns Black 1 ++ backRow White 5 [4,3..0] ++ pawns White 4
    pawns p y = [((x,y), Piece p Pawn) | x <- [0..4]]
    backRow p y xs = [((x,y), Piece p s) | (x,s) <- zip xs [King, Queen, Bishop, Knight, Rook]]

-- Play one white turn and one black turn, relaying the actions between the two agents. The constraint on the effects
-- in scope is the union of the two agent constraints, so this essentially interlaves the two effectful coroutines
-- that the agents represent into one.
-- Agents maintain all of their own state and are on the honor system to report game outcomes correctly.
tradeTurns :: (Members es effs, Members es' effs) => Agent es -> Agent es' -> Eff effs (Maybe GameOutcome)
tradeTurns w b = do
  act w >>= \case
    Tie -> return $ Just Draw
    Lose -> return $ Just $ Victor Black
    Win m' -> observe b m' >> return (Just (Victor White))
    Move m' -> observe b m' >> act b >>= \case
      Tie -> return $ Just Draw
      Lose -> return $ Just (Victor White)
      Win m''' -> observe w m''' >> return (Just (Victor Black))
      Move m''' -> observe w m''' >> return Nothing

-- Run a game to completion.
playGame :: (Members es effs, Members es' effs) => Agent es -> Agent es' -> Eff effs GameOutcome
playGame w b = untilJust $ tradeTurns w b
