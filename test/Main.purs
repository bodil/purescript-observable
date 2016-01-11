module Test.Main where

import Prelude
import Data.Array as Array
import Control.Alt ((<|>))
import Control.Monad.Aff (Aff, makeAff)
import Control.Monad.Aff.AVar (AVAR)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (CONSOLE)
import Control.Monad.Eff.Exception (Error, error)
import Control.Monad.Eff.Ref (REF, newRef, readRef, modifyRef)
import Control.Monad.Error.Class (catchError, throwError)
import Control.Observable (scan, foldr, foldl, fold, unwrap, never, singleton, Observable, OBSERVABLE, observe, fromFoldable)
import Control.Plus (empty)
import Data.Filterable (partition, filter)
import Data.Monoid (mempty, class Monoid)
import Test.Unit (TIMER, timeout, suite, test, Test)
import Test.Unit.Assert (expectFailure, equal)
import Test.Unit.Console (TESTOUTPUT)
import Test.Unit.Main (runTest)

collect :: forall a e m. (Monoid m) => (a -> m) -> Observable a -> Aff (ref :: REF, observable :: OBSERVABLE | e) m
collect wrap o = makeAff \reject resolve -> do
  coll <- newRef mempty
  let collectOne a = modifyRef coll (flip append (wrap a))
      allDone = readRef coll >>= resolve
  observe collectOne reject allDone o
  pure unit

expect :: forall a e. (Eq a, Show a) => Array a -> Observable a -> Test (observable :: OBSERVABLE, ref :: REF | e)
expect m o = do
  r <- collect Array.singleton o
  equal m r

main :: forall e. Eff (avar :: AVAR, timer :: TIMER, ref :: REF, console :: CONSOLE, testOutput :: TESTOUTPUT, observable :: OBSERVABLE | e) Unit
main = runTest do

  suite "basic constructors" do
    test "empty" do
      expect ([] :: Array Number) $ empty
    test "never" do
      expectFailure "never yielded a value" $ timeout 10 $ expect [1] never
    test "singleton" do
      expect ["lol"] $ singleton "lol"
    test "fromFoldable" do
      expect [1,2,3] $ fromFoldable [1,2,3]

  suite "basic type classes" do
    test "map" do
      expect [6,7,8] $ (+) 5 <$> fromFoldable [1,2,3]
    test "bind" do
      expect [1,1,2,2,3,3] $
        fromFoldable [1,2,3] >>= \i -> fromFoldable [i,i]
    test "append" do
      expect [1,2,3,1,2,3] $
      fromFoldable [1,2,3] <|> fromFoldable [1,2,3]
    test "mempty left" do
      expect [1,2,3] $
        empty <|> fromFoldable [1,2,3]
    test "mempty right" do
      expect [1,2,3] $
        fromFoldable [1,2,3] <|> empty

  suite "Filterable" do
    test "filter" do
      expect [1,2,3] $
        filter ((>) 4) $ fromFoldable [5,1,2,6,7,3,8,9]
    test "partition" do
      let o1 = partition ((>) 4) $ fromFoldable [5,1,2,6,7,3,8,9]
      expect [1,2,3] o1.no
      let o2 = partition ((>) 4) $ fromFoldable [5,1,2,6,7,3,8,9]
      expect [5,6,7,8,9] o2.yes

  suite "MonadError" do
    test "throwError" do
      expectFailure "throw didn't error" $ expect [1] $
        throwError (error "lol")
    test "catchError" do
      let o = fromFoldable [1,2,3]
          handle :: Error -> Observable Int
          handle _ = o
      expect [1,2,3] $ catchError (throwError (error "lol")) handle

  suite "Eff" do
    test "unwrap" do
      o <- liftEff $ unwrap $ fromFoldable [pure 1, pure 2, pure 3]
      expect [1,2,3] o

  suite "folds" do
    test "fold" do
      expect ["hello world"] $ fold $ fromFoldable ["hell", "o ", "world"]
    test "foldl" do
      expect ["worldo hell"] $ foldl (\acc next -> next <> acc) "" $
        fromFoldable ["hell", "o ", "world"]
    test "foldr" do
      expect ["worldo hell"] $ foldr (\next acc -> acc <> next) "" $
        fromFoldable ["hell", "o ", "world"]
    test "scan" do
      expect [1,3,6] $ scan (\acc next -> acc + next) 0 $ fromFoldable [1,2,3]
