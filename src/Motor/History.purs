
-- |
-- Supports serialising and deserialsing a History of actions, which can then
-- be replayed.

module Motor.History
  ( History
  , HistoryEntry
  -- * Update history
  , addGo, addTake, addExamine, addUse, addTalk, addSay
  -- * Serialise history
  , serialise, deserialse
  -- * Replay history
  , replayAll
  , initStory
  ) where

import Prelude (class Show, bind, discard, map, pure, show, ($), (*>), (<$>), (<*>), (<#>), (<<<), (<>), (>>=))
import Control.Alt ((<|>))
import Control.Monad.State (class MonadState, get)
import Data.Array ((:))
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (foldM)
import Data.List as L
import Data.Maybe (Maybe(..))
import Data.String (null) as S
import Data.String.CodeUnits (fromCharArray) as S
import Data.Tuple (Tuple(..))
import Debug.Trace (trace)
import Text.Parsing.Parser (Parser, runParser)
import Text.Parsing.Parser.Combinators (lookAhead, manyTill, sepBy, try)
import Text.Parsing.Parser.String (noneOf, string)

import Motor.Interpreter.ActionInterpreter (runAction)
import Motor.Story.Lens (sInit, sSay, (^.), (.=))
import Motor.Story.Types (Story)
import Motor.Util (goto, lookupOidByTitle, lookupRoomAction, lookupSay, useItself, useWith, takeItemS, toObject, toRoom)


data HistoryEntry
  = HGo      String
  | HTake    String
  | HExamine String
  | HUse     String (Maybe String)
  | HTalk    String
  | HSay     String

instance historyEntryShow ∷ Show HistoryEntry where
  show = toText
  -- show (HGo s) = "Go " <> s
  -- show (HTake s) = "Take " <> s
  -- show (HExamine s) = "Examine " <> s
  -- show (HUse s ms) = "Use " <> s <> " " <> show ms
  -- show (HTalk s) = "Talk" <> s
  -- show (HSay s) = "Say " <> s


type History = Array HistoryEntry

-- | Add go instruction to 'History'.
addGo ∷ String → History → History
addGo t = ((HGo t) : _)

-- | Add take instruction to 'History'.
addTake ∷ String → History → History
addTake t = ((HTake t) : _)

-- | Add examine instruction to 'History'.
addExamine ∷ String → History → History
addExamine t = ((HExamine t) : _)

-- | Add use instruction to 'History'.
addUse ∷ String → Maybe String → History → History
addUse t1 mt2 = ((HUse t1 mt2) : _)

-- | Add talk instruction to 'History'.
addTalk ∷ String → History → History
addTalk t = ((HTalk t) : _)

-- | Add say instruction to 'History'.
addSay ∷ String → History → History
addSay t = ((HSay t) : _)

replay
  ∷ ∀ m
  . MonadState Story m
  ⇒ (Either String (Array String))
  → HistoryEntry
  → m (Either String (Array String))
replay _ (HGo dir) = trace ("HGo " <> dir) \_ → do
  eRoomAction ← lookupRoomAction dir
  case eRoomAction of
    Right roomAction → do
      eRid ← goto roomAction
      case eRid of
        Left  txt → pure $ Right txt
        Right rid → do room ← toRoom rid
                       txt  ← runAction room.descr
                       pure $ Right txt
    Left err → pure $ Left err

replay _ (HTake oName) = trace ("HTake " <> oName) \_ → do
  eOid ← lookupOidByTitle oName
  case eOid of
    Right oid → do _ ← takeItemS oid
                   pure $ Right []
    Left err → pure $ Left err

replay _ (HExamine oName) = trace ("HExamine " <> oName) \_ → do
  eOid ← lookupOidByTitle oName
  case eOid of
    Right oid → do o   ← toObject oid
                   txt ← runAction o.descr
                   pure $ Right txt
    Left err → pure $ Left err

replay _ (HUse oName1 mOName2) = trace ("HUse " <> oName1 <> " `with` " <> show mOName2) \_ → do
  case mOName2 of
    Just oName2 → replayUseWith oName1 oName2
    Nothing     → replayUse oName1

replay _ (HTalk who) = trace ("HTalk " <> who) \_ → do
  sSay .= []
  eOid ← lookupOidByTitle who
  case eOid of
    Right oid → do o ← toObject oid
                   case o.talk of
                     Just action → do txt ← runAction action
                                      pure $ Right txt
                     Nothing → pure $ Left "no talk action..."
    Left err → pure $ Left err

replay _ (HSay say') = trace ("HSay " <> say') \_ → do
  eAtn ← lookupSay say'
  case eAtn of
    Right atn → do sSay .= []
                   txt ← runAction atn
                   pure $ Right txt
    Left err → pure $ Left err

replayUseWith ∷ ∀ m. MonadState Story m ⇒ String → String → m (Either String (Array String))
replayUseWith oName1 oName2 = do
  eOid1 ← lookupOidByTitle oName1
  eOid2 ← lookupOidByTitle oName2
  case Tuple eOid1 eOid2 of
    Tuple (Right oid1) (Right oid2) → map Right $ useWith oid1 oid2
    Tuple (Left err)   _            → pure $ Left err
    Tuple _            (Left err  ) → pure $ Left err

replayUse ∷ ∀ m. MonadState Story m ⇒ String → m (Either String (Array String))
replayUse oName = do
  eOid ← lookupOidByTitle oName
  case eOid of
    Right oid → useItself oid
    Left  err → pure $ Left err


historiesP ∷  Parser String History
historiesP = map L.toUnfoldable $ sepBy historyP (string "\n")
  where
    upToEol ∷ Parser String String
    upToEol = S.fromCharArray <$> A.many (noneOf ['\n'])
    upToEolOrWith ∷ Parser String String
    upToEolOrWith = map (S.fromCharArray <<< L.toUnfoldable) (manyTill (noneOf ['\n']) (try $  (string " with ")
                                                                                <|> (lookAhead $ string "\n")))
    b ∷ Parser String String
    b = S.fromCharArray <$> A.some (noneOf ['\n'])
    c ∷ Parser String (Maybe String)
    c = (b <#> Just) <|> pure Nothing
    historyP =   try (string "go "      *> (HGo      <$> upToEol))
             <|> try (string "take "    *> (HTake    <$> upToEol))
             <|> try (string "examine " *> (HExamine <$> upToEol))
             <|> try (string "use "     *> (HUse     <$> upToEolOrWith <*> c))
             <|> try (string "talk to " *> (HTalk    <$> upToEol))
             <|> try (string "say "     *> (HSay     <$> upToEol))

replay'
  ∷ ∀ m
  . MonadState Story m
  ⇒ Tuple History (Either String (Array String))
  → HistoryEntry
  → m (Tuple History (Either String (Array String)))
replay' (Tuple hs e@(Right txts)) h = do
  res ← replay e h
  pure $ case res of
    Right txts' → Tuple (h : hs) (Right (txts <> txts'))
    Left  err   → Tuple      hs  (Left err)
replay' (Tuple hs e) _ = pure $ Tuple hs e

-- | Replay 'Text' of history on 'Story'.
--
-- If it fails, it will still have updated the story as far as it could, and
-- return the portion of history which was successfully applied, as well as an
-- error message.
replayAll
  ∷ ∀ m
  . MonadState Story m
  ⇒ String
  → m (Tuple History (Either String (Array String)))
replayAll ser =
  case deserialse ser of
    Right histories → foldM replay' (Tuple [] (Right [])) (A.reverse histories)
    Left  err       → pure $ Tuple [] (Left err)


toText ∷ HistoryEntry → String
toText (HGo     t           ) = "go "      <> t
toText (HTake   t           ) = "take "    <> t
toText (HExamine t          ) = "examine " <> t
toText (HUse    t1 (Just t2)) = "use " <> t1 <> " with " <> t2
toText (HUse    t1 Nothing  ) = "use " <> t1
toText (HTalk   t           ) = "talk to " <> t
toText (HSay    t           ) = "say "     <> t

-- | Convert 'History' into 'String' representation
serialise ∷ History → String
serialise = A.intercalate "\n" <<< map toText

-- | Convert 'String' representation back into 'History'
deserialse ∷ String → Either String History
deserialse s = case runParser s historiesP of
                 Left pe → Left $ show pe
                 Right h → Right h

--------------------------------------------------------------------------------

initStory
  ∷ ∀ m
  . MonadState Story m
  ⇒ String
  → m (Either { restoredPath ∷ String
              , error        ∷ String
              }
              { historicTxt ∷ Array String
              , initTxt     ∷ Array String
              }
      )
initStory path = do
  story ← get
  initTxt ← runAction $ story ^. sInit
  res ← replayAll path
  trace ("replayAll returned: " <> show res) \_ → pure $ case res of
    Tuple _ (Right historicTxt) → Right { historicTxt
                                        , initTxt: if S.null path then initTxt else []
                                        }
    Tuple h (Left error)        → Left { restoredPath : serialise h
                                       , error
                                       }
