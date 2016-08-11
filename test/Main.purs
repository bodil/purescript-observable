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
import Control.Observable (zip, concat, foldp, foldr, foldl, fold, unwrap, never, singleton, Observable, OBSERVABLE, observe, fromFoldable)
import Control.Plus (empty)
import Data.Filterable (partition, filter)
import Data.Maybe (Maybe(Just, Nothing))
import Data.Monoid (mempty, class Monoid)
import Data.Tuple (Tuple(Tuple))
import Data.Unfoldable (unfoldr)
import Test.Unit (TIMER, timeout, suite, test, Test)
import Test.Unit.Assert (expectFailure, equal)
import Test.Unit.Console (TESTOUTPUT)
import Test.Unit.Main (runTest)

collectVals :: forall a e m. (Monoid m) => (a -> m) -> Observable a -> Aff (ref :: REF, observable :: OBSERVABLE | e) m
collectVals wrap o = makeAff \reject resolve -> do
  coll <- newRef mempty
  let collectOne a = modifyRef coll (flip append (wrap a))
      allDone = readRef coll >>= resolve
  observe collectOne reject allDone o
  pure unit

expect :: forall a e. (Eq a, Show a) => Array a -> Observable a -> Test (observable :: OBSERVABLE, ref :: REF | e)
expect m o = do
  r <- collectVals Array.singleton o
  equal m r

expectEqual :: forall a e. (Eq a, Show a) => Observable a -> Observable a -> Test (observable :: OBSERVABLE, ref :: REF | e)
expectEqual o1 o2 = do
  r1 <- collectVals Array.singleton o1
  r2 <- collectVals Array.singleton o2
  equal r1 r2

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

  suite "Monoid" do
    test "append" do
      expect [1,1,2,2,3,3] $
      fromFoldable [1,2,3] <|> fromFoldable [1,2,3]
    test "mempty left" do
      expect [1,2,3] $
        empty <|> fromFoldable [1,2,3]
    test "mempty right" do
      expect [1,2,3] $
        fromFoldable [1,2,3] <|> empty

  suite "Functor" do
    test "map" do
      expect [6,7,8] $ (+) 5 <$> fromFoldable [1,2,3]
    test "identity" do
      let l = fromFoldable [1,2,3]
      expectEqual (id <$> l) l
    test "composition" do
      let f = \v -> v <> "o"
          g = \v -> v <> "l"
          l = fromFoldable ["lol", "wat"]
      expectEqual (map (f <<< g) l) (((map f) <<< (map g)) l)

  suite "Applicative" do
    test "apply" do
      expect [[1,4],[2,4],[2,5],[3,5],[3,6]] $ (\a b -> [a,b]) <$> fromFoldable [1,2,3] <*> fromFoldable [4,5,6]
    test "identity" do
      let a = fromFoldable [1,2,3]
      expectEqual ((pure id) <*> a) a
    test "homomorphism" do
      let f = \v -> v + 10
          x = 20
      expectEqual ((singleton f) <*> (singleton x)) (singleton (f x))
    test "associative composition" do
      let f = fromFoldable [\v -> v + 1, \v -> v * 10]
          g = fromFoldable [\v -> v + 10, \v -> v * 100]
          h = fromFoldable [1,2,3]
      expectEqual ((<<<) <$> f <*> g <*> h) (f <*> (g <*> h))

  suite "Monad" do
    test "bind" do
      expect [1,1,2,2,3,3] $
        fromFoldable [1,2,3] >>= \i -> fromFoldable [i,i]
    test "associativity" do
      let f = \i -> fromFoldable [i+5]
          g = \i -> fromFoldable [i,i]
          x = fromFoldable [1,2,3]
      expectEqual ((x >>= f) >>= g) (x >>= (\k -> f k >>= g))
    test "left identity" do
      let f = \v -> singleton $ v + 5
          x = 10
      expectEqual (singleton x >>= f) (f x)
    test "right identity" do
      let x = singleton 10
      expectEqual (x >>= pure) x

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

  suite "Foldable" do
    test "fold" do
      expect ["hello world"] $ fold $ fromFoldable ["hell", "o ", "world"]
    test "foldl" do
      expect ["worldo hell"] $ foldl (\acc next -> next <> acc) "" $
        fromFoldable ["hell", "o ", "world"]
    test "foldr" do
      expect ["worldo hell"] $ foldr (\next acc -> acc <> next) "" $
        fromFoldable ["hell", "o ", "world"]
    test "foldp" do
      expect [1,3,6] $ foldp (\acc next -> acc + next) 0 $ fromFoldable [1,2,3]

  suite "Unfoldable" do
    test "unfoldr" do
      let f l = case Array.uncons l of
            Nothing -> Nothing
            Just {head, tail} -> Just (Tuple head tail)
      expect [1,2,3] $ unfoldr f [1,2,3]

  suite "extras" do
    test "concat" do
      expect [1,2,3,4,5,6] $ concat (fromFoldable [1,2,3]) (fromFoldable [4,5,6])
    test "zip" do
      expect [[1,1], [2,2], [3,3]] $ zip (\a b -> [a, b]) (fromFoldable [1,2,3]) (fromFoldable [1,2,3])
