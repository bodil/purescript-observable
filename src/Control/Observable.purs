module Control.Observable
  ( Observable
  , OBSERVABLE
  , Subscription
  , Observer
  , SubscriberFunction
  , EffO
  , observable
  , subscribe
  , observe
  , free
  , empty
  , never
  , singleton
  , fromFoldable
  , unwrap
  , foldMap
  , fold
  , foldl
  , foldr
  , foldp
  , scan
  , concat
  , zip
  , zip3
  , zip4
  , zip5
  , take
  , takeWhile
  , takeUntil
  , drop
  , dropWhile
  , dropUntil
  , distinct
  , sampleOn
  , bufferOn
  ) where

import Prelude
import Data.CatList as Cat
import Data.Foldable as Foldable
import Data.List as List
import Control.Alt (class Alt)
import Control.Alternative (class Alternative)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Exception (Error)
import Control.Monad.Eff.Unsafe (unsafePerformEff)
import Control.Monad.Error.Class (class MonadError)
import Control.Monad.ST (ST, writeSTRef, runST, modifySTRef, readSTRef, newSTRef)
import Control.MonadPlus (class MonadPlus)
import Control.MonadZero (class MonadZero)
import Control.Plus (class Plus)
import Data.Either (either, Either)
import Data.Filterable (filterDefault, partitionDefault, class Filterable)
import Data.Foldable (for_, traverse_, class Foldable)
import Data.List (List(Cons, Nil))
import Data.Maybe (isNothing, maybe, Maybe(Nothing, Just))
import Data.Monoid (mempty, class Monoid)
import Data.Tuple (Tuple(Tuple))
import Data.Unfoldable (class Unfoldable)

foreign import data OBSERVABLE :: !

type EffO e a = Eff (observable :: OBSERVABLE | e) a

foreign import schedule :: forall e. EffO e Unit -> EffO e Unit
foreign import _bind :: forall a b. Observable a -> (a -> Observable b) -> Observable b

-- | An `Observable` represents a finite stream of asynchronous values.
-- | You can attach `Observer`s to it to react to events such as new values,
-- | errors and stream completion (no more values).
foreign import data Observable :: * -> *

-- | An `Observer` contains a set of functions which will be called when the
-- | corresponding event occurs on an `Observable` it is subscribed to.
type Observer e a = {
  next :: a -> EffO e Unit,
  error :: Error -> EffO e Unit,
  complete :: EffO e Unit
  }

-- | A `Subscription` represents an `Observer` listening to an `Observable`.
-- | To stop receiving events, you may call the `unsubscribe` function it
-- | wraps.
type Subscription e = {
  unsubscribe :: EffO e Unit
  }

type SubscriberFunction e a =
  Observer e a -> EffO e (Subscription e)

-- | Create an observable.
-- |
-- | This function takes a `SubscriberFunction`, which will be called with an
-- | `Observer` as argument whenever the `Observable`'s subscriber count goes
-- | from zero to one. It can call functions on the provided `Observer` to
-- | trigger events on the `Observable`. It must return a `Subscription`,
-- | which provides an `unsubscribe` function that will be called whenever the
-- | `Observable`'s subscriber count goes from one to zero.
foreign import observable :: forall e a. SubscriberFunction e a -> EffO e (Observable a)

-- | Subscribe an `Observer` to an `Observable`.
foreign import subscribe :: forall e a. Observer e a -> Observable a -> EffO e (Subscription e)

-- | Subscribe to an `Observable` using callback functions.
-- |
-- | This is simply a shorthand for constructing an `Observer` and calling
-- | `subscribe`.
observe :: forall e a. (a -> EffO e Unit) -> (Error -> EffO e Unit) -> (EffO e Unit) -> Observable a -> EffO e (Subscription e)
observe next error complete = subscribe { next, error, complete }

unsafeObservable :: forall a s. SubscriberFunction (st :: ST s) a -> Observable a
unsafeObservable = observable >>> unsafePerformEff



-- | Create and return a `Subscription` which will unsubscribe from
-- | the list of `Subscription`s you provide when its `unsubscribe`
-- | method is called.
-- |
-- | Use this to easily finish up your subscriber functions.
-- |
-- | Examples:
-- |
-- |     -- this is how the `never` function is implemented:
-- |     subscriberFn sink = free []
-- |
-- |     subscriberFn sink = do
-- |       sub <- subscribe next error complete inputObs
-- |       unsub [sub]
free :: forall e. Array (Subscription e) -> EffO e (Subscription e)
free [] = pure {unsubscribe: pure unit}
free subs = pure {unsubscribe: for_ subs _.unsubscribe}



-- | An observable which completes immediately without yielding any values.
empty :: forall a. Observable a
empty = unsafeObservable \sink -> do
  sink.complete
  free []

-- | An observable which never yields any values and never completes.
never :: forall a. Observable a
never = unsafeObservable \sink -> free []

-- | Make an observable which only yields the provided value on the next tick,
-- | then immediately closes.
singleton :: forall a. a -> Observable a
singleton v = unsafeObservable \sink -> do
  schedule do
    sink.next v
    sink.complete
  free []

-- | Convert any `Foldable` into an observable. It will yield each value from
-- | the `Foldable` in order every tick until it's empty, then complete.
fromFoldable :: forall f. Foldable f => f ~> Observable
fromFoldable f = unsafeObservable \sink -> do
  let run Nil = schedule sink.complete
      run (Cons h t) = schedule do
        sink.next h
        run t
  run (List.fromFoldable f)
  free []

-- | Convert an `Observable` of effects producing values into an effect
-- | producing an `Observable` of the produced values.
unwrap :: forall a e. Observable (EffO e a) -> EffO e (Observable a)
unwrap o = observable \sink -> do
  sub <- observe (_ >>= sink.next) sink.error sink.complete o
  free [sub]



-- | Merge two `Observable`s together, so that the resulting `Observable`
-- | will yield all values from both source `Observable`s, throw an error
-- | if either of the sources throw an error, and complete once both
-- | sources complete.
merge :: forall a. Observable a -> Observable a -> Observable a
merge o1 o2 = unsafeObservable \sink -> do
  closed <- newSTRef 0
  subs <- newSTRef []
  let unsub = readSTRef subs >>= traverse_ \s -> s.unsubscribe
      done = do
        c <- modifySTRef closed (_ + 1)
        if c >= 2 then unsub *> sink.complete else pure unit
      error e = unsub *> sink.error e
  sub1 <- observe sink.next error done o1
  sub2 <- observe sink.next error done o2
  writeSTRef subs [sub1, sub2]
  free [sub1, sub2]

filterMap :: forall a b. (a -> Maybe b) -> Observable a -> Observable b
filterMap f o = unsafeObservable \sink -> do
  let yield = f >>> maybe (pure unit) sink.next
  sub <- observe yield sink.error sink.complete o
  free [sub]

partitionMap :: forall a l r. (a -> Either l r) -> Observable a -> { left :: Observable l, right :: Observable r }
partitionMap f o =
  let left = filterMap pickLeft o
      right = filterMap pickRight o
      pickLeft = f >>> either Just (const Nothing)
      pickRight = f >>> either (const Nothing) Just
  in { left, right }



-- | Given a function which maps a value of type `a` to some `Monoid`,
-- | `foldMap` creates an `Observable` which will do nothing until the
-- | source `Observable` completes, then yield the result of adding up
-- | all the values produced by the source, mapped through the function.
-- | It completes immediately after yielding that value.
foldMap :: forall a m. Monoid m => (a -> m) -> Observable a -> Observable m
foldMap f = foldl (\acc next -> append acc (f next)) mempty

-- | Given an `Observable` of some `Monoid`, create an `Observable` which
-- | collects and adds together all the values yielded by the source
-- | `Observable`, then, as soon as the source completes, yields the
-- | collected result.
fold :: forall m. Monoid m => Observable m -> Observable m
fold = foldl append mempty

-- | Perform a left fold over an `Observable`, yielding the result
-- | once the input `Observable` completes.
foldl :: forall a b. (b -> a -> b) -> b -> Observable a -> Observable b
foldl f i o = unsafePerformEff $ runST do
  acc <- newSTRef i
  observable \sink -> do
    let next v = void $ modifySTRef acc (flip f v)
        done = do
          readSTRef acc >>= sink.next
          sink.complete
    sub <- observe next sink.error done o
    free [sub]

-- | Perform a right fold over an `Observable`, yielding the result
-- | once the input `Observable` completes.
-- |
-- | Note that this operation needs to keep every value from the input
-- | in memory until it completes, so use with caution.
foldr :: forall a b. (a -> b -> b) -> b -> Observable a -> Observable b
foldr f i o = Foldable.foldr f i <$> foldMap List.singleton o

-- | Perform an operation like a left fold over the input `Observable`,
-- | but instead of waiting until the input completes to yield the
-- | result, it yields each intermediate value as it happens.
-- |
-- | This is basically like `map`, except that you get the previous
-- | output value passed into your mapping function as well as the
-- | input value. This is great for evolving state: if the input
-- | `Observable` contains actions, the scanning function gets your
-- | previous state and an action as inputs, and returns the new state.
foldp :: forall a b. (b -> a -> b) -> b -> Observable a -> Observable b
foldp f i o = unsafePerformEff $ runST do
  ref <- newSTRef i
  observable \sink -> do
    let next v = modifySTRef ref (flip f v) >>= sink.next
    sub <- observe next sink.error sink.complete o
    free [sub]

-- | An alias for `foldp` to make RxJS users feel at home.
scan :: forall a b. (b -> a -> b) -> b -> Observable a -> Observable b
scan = foldp



-- | Combine two observables by yielding values only from the first until
-- | it completes, then yielding values from the second.
concat :: forall a. Observable a -> Observable a -> Observable a
concat a b = unsafeObservable \sink -> do
  active <- newSTRef Nothing
  let unsub = readSTRef active >>= maybe (pure unit) _.unsubscribe
  let nextObs = do
        unsub
        observe sink.next sink.error sink.complete b >>= Just >>> writeSTRef active
        pure unit
  observe sink.next sink.error nextObs a >>= Just >>> writeSTRef active
  pure {unsubscribe: unsub}



-- | Given two `Observable`s, wait until both have yielded values before
-- | combining them using the provided function and yielding an output value.
-- |
-- | Example:
-- |
-- |     zip (fromFoldable [1,2,3]) (fromFoldable [4,5,6])
-- |     -- yields the following: [1,4], [2,5], [3,6], complete.
zip :: forall a b c. (a -> b -> c) -> Observable a -> Observable b -> Observable c
zip f o1 o2 = unsafeObservable \sink -> do
  subs <- newSTRef []
  active <- newSTRef 2
  queue <- newSTRef (Tuple Cat.empty Cat.empty)
  let unsub = readSTRef subs >>= traverse_ \s -> s.unsubscribe
      next1 v = (modifySTRef queue \(Tuple q1 q2) -> Tuple (Cat.snoc q1 v) q2) >>= push
      next2 v = (modifySTRef queue \(Tuple q1 q2) -> Tuple q1 (Cat.snoc q2 v)) >>= push
      push (Tuple q1 q2) = case Cat.uncons q1, Cat.uncons q2 of
          Nothing, _ -> pure unit
          _, Nothing -> pure unit
          Just (Tuple h1 t1), Just (Tuple h2 t2) -> do
            writeSTRef queue (Tuple t1 t2)
            sink.next (f h1 h2)
      done = do
        c <- modifySTRef active (_ - 1)
        when (c == 0) (unsub *> sink.complete)
      error e = unsub *> sink.error e
  sub1 <- observe next1 error done o1
  sub2 <- observe next2 error done o2
  writeSTRef subs [sub1, sub2]
  pure {unsubscribe: unsub}

-- | Like `zip`, except with three source `Observable`s.
zip3 :: forall a b c d. (a -> b -> c -> d) -> Observable a -> Observable b -> Observable c -> Observable d
zip3 f a b c = zip (\f c -> f c) (zip (\a b -> \c -> f a b c) a b) c

-- | Like `zip`, except with four source `Observable`s.
zip4 :: forall a b c d e. (a -> b -> c -> d -> e) -> Observable a -> Observable b -> Observable c -> Observable d -> Observable e
zip4 f a b c d = zip (\f d -> f d) (zip3 (\a b c -> \d -> f a b c d) a b c) d

-- | Like `zip`, except with five source `Observable`s.
zip5 :: forall a b c d e f. (a -> b -> c -> d -> e -> f) -> Observable a -> Observable b -> Observable c -> Observable d -> Observable e -> Observable f
zip5 f a b c d e = zip (\f e -> f e) (zip4 (\a b c d -> \e -> f a b c d e) a b c d) e



-- | Take only the first `n` values from the source `Observable`.
take :: forall a. Int -> Observable a -> Observable a
take 0 _ = empty
take n o = unsafeObservable \sink -> do
  count <- newSTRef 0
  let next v = do
        c <- modifySTRef count (_ + 1)
        sink.next v
        when (c >= n) sink.complete
  sub <- observe next sink.error sink.complete o
  free [sub]

-- | Pass through values from the source `Observable` only as long as
-- | a predicate holds `true`.
-- |
-- | Unlike `filter`, the output `Observable` will actually complete the
-- | first time the predicate function returns `false`.
takeWhile :: forall a. (a -> Boolean) -> Observable a -> Observable a
takeWhile pred o = unsafeObservable \sink -> do
  let next v = if pred v then sink.next v else sink.complete
  sub <- observe next sink.error sink.complete o
  free [sub]

-- | Pass through values from the source `Observable` only until
-- | the other `Observable` starts yielding values or completes,
-- | then complete as soon as that happens.
takeUntil :: forall a b. Observable b -> Observable a -> Observable a
takeUntil b a = unsafeObservable \sink -> do
  sub1 <- observe sink.next sink.error sink.complete a
  sub2 <- observe (const sink.complete) sink.error sink.complete b
  free [sub1, sub2]



-- | Drop the first `n` values from the source `Observable`.
drop :: forall a. Int -> Observable a -> Observable a
drop 0 _ = empty
drop n o = unsafeObservable \sink -> do
  count <- newSTRef 0
  let next v = do
        c <- modifySTRef count (_ + 1)
        when (c > n) $ sink.next v
  sub <- observe next sink.error sink.complete o
  free [sub]

-- | Don't pass through values from the source `Observable` while a given
-- | predicate holds true.
dropWhile :: forall a. (a -> Boolean) -> Observable a -> Observable a
dropWhile pred o = unsafeObservable \sink -> do
  ready <- newSTRef false
  let next v = do
        reading <- readSTRef ready
        if reading then sink.next v else unless (pred v) do
          writeSTRef ready true
          sink.next v
  sub <- observe next sink.error sink.complete o
  free [sub]

-- | Wait until one `Observable` yields a value (which is ignored),
-- | or until it completes, before passing through values from the
-- | other `Observable`.
dropUntil :: forall a b. Observable b -> Observable a -> Observable a
dropUntil b a = unsafeObservable \sink -> do
  source <- newSTRef Nothing
  trigger <- newSTRef Nothing
  let unsubscribe = do
        readSTRef trigger >>= maybe (pure unit) (_.unsubscribe)
        readSTRef source >>= maybe (pure unit) (_.unsubscribe)
      ready = do
        readSTRef trigger >>= maybe (pure unit) (_.unsubscribe)
        void $ writeSTRef trigger Nothing
      next v = do
        readyState <- isNothing <$> readSTRef trigger
        when readyState $ sink.next v
  observe next sink.error sink.complete a >>= Just >>> writeSTRef source
  observe (const ready) sink.error ready b >>= Just >>> writeSTRef trigger
  pure {unsubscribe}



-- | Only yield values from the source `Observable` if they're not
-- | the same as the previous value.
-- |
-- | Example:
-- |
-- |     distinct (fromFoldable [1,2,2,3,3,3])
-- |     -- yields: 1, 2, 3, complete.
distinct :: forall a. (Eq a) => Observable a -> Observable a
distinct o = unsafeObservable \sink -> do
  last <- newSTRef Nothing
  let next v = do
        lastV <- readSTRef last
        writeSTRef last (Just v)
        when ((Just v) /= lastV) $ sink.next v
  sub <- observe next sink.error sink.complete o
  free [sub]



-- | Every time the first `Observable` yields a value, yield instead
-- | the last value that was yielded by the second `Observable`.
sampleOn :: forall a b. Observable b -> Observable a -> Observable a
sampleOn trigger source = unsafeObservable \sink -> do
  last <- newSTRef Nothing
  let nextSource v = void $ writeSTRef last (Just v)
      yield = readSTRef last >>= maybe (pure unit) sink.next
  sub1 <- observe nextSource sink.error sink.complete source
  sub2 <- observe (const yield) sink.error sink.complete trigger
  free [sub1, sub2]



-- | Every time the first `Observable` yields, yield a `CatList` of
-- | values that have been yielded by the second `Observable` since the
-- | last time the first one yielded.
bufferOn :: forall a b. Observable b -> Observable a -> Observable (Cat.CatList a)
bufferOn trigger source = unsafeObservable \sink -> do
  buf <- newSTRef Cat.empty
  let nextSource v = void $ modifySTRef buf (flip Cat.snoc v)
      yield = do
        readSTRef buf >>= sink.next
        void $ writeSTRef buf Cat.empty
  sub1 <- observe nextSource sink.error sink.complete source
  sub2 <- observe (const yield) sink.error sink.complete trigger
  free [sub1, sub2]



instance functorObservable :: Functor Observable where
  map f o = unsafeObservable \sink -> do
    sub <- observe (\v -> sink.next (f v)) sink.error sink.complete o
    free [sub]

instance bindObservable :: Bind Observable where
  bind = _bind

instance applyObservable :: Apply Observable where
  apply f o = unsafeObservable \sink -> do
    fun <- newSTRef Nothing
    val <- newSTRef Nothing
    active <- newSTRef 2
    let nextFun f = do
          writeSTRef fun (Just f)
          readSTRef val >>= maybe (pure unit) (f >>> sink.next)
    let nextVal v = do
          writeSTRef val (Just v)
          readSTRef fun >>= maybe (pure unit) (\f -> sink.next (f v))
    let done = do
          c <- modifySTRef active (_ - 1)
          when (c == 0) sink.complete
    funsub <- observe nextFun sink.error done f
    valsub <- observe nextVal sink.error done o
    free [funsub, valsub]

instance applicativeObservable :: Applicative Observable where
  pure = singleton

instance monadObservable :: Monad Observable

instance altObservable :: Alt Observable where
  alt = merge

instance plusObservable :: Plus Observable where
  empty = empty

instance alternativeObservable :: Alternative Observable

instance monadZeroObservable :: MonadZero Observable

instance monadPlusObservable :: MonadPlus Observable

instance filterableObservable :: Filterable Observable where
  partitionMap f o = partitionMap f o
  partition f o = partitionDefault f o
  filterMap f o = filterMap f o
  filter f o = filterDefault f o

instance monadErrorObservable :: MonadError Error Observable where
  throwError e = unsafeObservable \sink -> sink.error e *> free []

  catchError o f = unsafeObservable \sink -> do
    subs <- newSTRef []
    let unsub = do
          readSTRef subs >>= traverse_ _.unsubscribe
          void $ writeSTRef subs []
        handle e = do
          unsub
          nextSub <- subscribe sink (f e)
          void $ writeSTRef subs [nextSub]
    firstSub <- observe sink.next handle sink.complete o
    writeSTRef subs [firstSub]
    pure {unsubscribe: unsub}

instance semigroupObservable :: Semigroup (Observable a) where
  append = merge

instance monoidObservable :: Monoid (Observable a) where
  mempty = empty

instance unfoldableObservable :: Unfoldable Observable where
  unfoldr f s = unsafeObservable \sink -> do
    let run b = case f b of
          Nothing -> schedule sink.complete
          Just (Tuple a b1) -> schedule do
            sink.next a
            run b1
    run s
    free []
