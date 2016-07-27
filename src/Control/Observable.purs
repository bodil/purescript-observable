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
  , noUnsub
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
  ) where

import Prelude
import Control.Alt (class Alt)
import Control.Alternative (class Alternative)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Exception (Error)
import Control.Monad.Eff.Unsafe (unsafePerformEff)
import Control.Monad.Error.Class (class MonadError)
import Control.Monad.ST (writeSTRef, runST, modifySTRef, readSTRef, newSTRef)
import Control.MonadPlus (class MonadPlus)
import Control.MonadZero (class MonadZero)
import Control.Plus (class Plus)
import Data.Either (either, Either)
import Data.Filterable (filterDefault, partitionDefault, class Filterable)
import Data.Foldable as Foldable
import Data.Foldable (traverse_, class Foldable)
import Data.List as List
import Data.Maybe (maybe, Maybe(Nothing, Just))
import Data.Monoid (mempty, class Monoid)

foreign import data OBSERVABLE :: !

type EffO e a = Eff (observable :: OBSERVABLE | e) a

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

unsafeObservable :: forall e a. SubscriberFunction e a -> Observable a
unsafeObservable = observable >>> unsafePerformEff



-- | If your observable doesn't need to free any resources on unsubscribe,
-- | just call `noUnsub` at the end of your subscriber function. It will return
-- | a subscription with a no-op unsubscribe function.
noUnsub :: forall e. EffO e (Subscription e)
noUnsub = pure {unsubscribe: pure unit}

unsub1 :: forall e. Subscription e -> EffO e (Subscription e)
unsub1 sub = pure {unsubscribe: sub.unsubscribe}

unsub2 :: forall e. Subscription e -> Subscription e -> EffO e (Subscription e)
unsub2 sub1 sub2 = pure {unsubscribe: sub1.unsubscribe *> sub2.unsubscribe}



-- | An observable which completes immediately without yielding any values.
foreign import empty :: forall a. Observable a

-- | An observable which never yields any values and never completes.
never :: forall a. Observable a
never = unsafeObservable \sink -> noUnsub

-- | Make an observable which only yields the provided value, then immediately
-- | closes.
singleton :: forall a. a -> Observable a
singleton v = unsafeObservable \sink -> do
  sink.next v
  sink.complete
  noUnsub

-- | Convert any `Foldable` into an observable. It will yield each value from
-- | the `Foldable` immediately, then complete.
fromFoldable :: forall a f. Foldable f => f a -> Observable a
fromFoldable f = unsafeObservable \sink -> do
  traverse_ (sink.next) f
  sink.complete
  noUnsub

-- | Convert an `Observable` of effects producing values into an effect
-- | producing an `Observable` of the produced values.
unwrap :: forall a e. Observable (EffO e a) -> EffO e (Observable a)
unwrap o = observable \sink -> do
  sub <- observe ((=<<) sink.next) sink.error sink.complete o
  unsub1 sub



-- | Merge two `Observable`s together, so that the resulting `Observable`
-- | will yield all values from both source `Observable`s, throw an error
-- | if either of the sources throw an error, and complete once both
-- | sources complete.
merge :: forall a. Observable a -> Observable a -> Observable a
merge o1 o2 = unsafeObservable \sink -> do
  closed <- newSTRef 0
  subs <- newSTRef []
  let unsub = readSTRef subs >>= traverse_ _.unsubscribe
      done = do
        c <- modifySTRef closed (_ + 1)
        if c >= 2 then unsub *> sink.complete else pure unit
      error e = unsub *> sink.error e
  sub1 <- observe sink.next error done o1
  sub2 <- observe sink.next error done o2
  writeSTRef subs [sub1, sub2]
  unsub2 sub1 sub2

filterMap :: forall a b. (a -> Maybe b) -> Observable a -> Observable b
filterMap f o = unsafeObservable \sink -> do
  let yield = f >>> maybe (pure unit) sink.next
  sub <- observe yield sink.error sink.complete o
  unsub1 sub

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
    unsub1 sub

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
    unsub1 sub

-- | An alias for `foldp` to make RxJS users feel at home.
scan :: forall a b. (b -> a -> b) -> b -> Observable a -> Observable b
scan = foldp



instance functorObservable :: Functor Observable where
  map f o = unsafeObservable \sink ->
    observe (\v -> sink.next (f v)) sink.error sink.complete o >>= unsub1

instance bindObservable :: Bind Observable where
  bind o f = unsafeObservable \sink -> do
    active <- newSTRef 1
    subs <- newSTRef []
    let unsub = readSTRef subs >>= traverse_ _.unsubscribe
        closed = do
          c <- modifySTRef active (_ - 1)
          if c < 1 then unsub *> sink.complete else pure unit
        error e = unsub *> sink.error e
        next v = do
          sub1 <- observe sink.next error closed (f v)
          modifySTRef subs (append [sub1])
          void $ modifySTRef active (_ + 1)
    sub <- observe next error closed o
    modifySTRef subs (append [sub])
    pure {unsubscribe: unsub}

instance applyObservable :: Apply Observable where
  apply = ap

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
  throwError e = unsafeObservable \sink -> sink.error e *> noUnsub

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
