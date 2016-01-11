# purescript-observable

Observables for PureScript, compatible with the
[ECMAScript Observable proposal](https://github.com/zenparsing/es-observable).

* [API docs on Pursuit](http://pursuit.purescript.org/packages/purescript-observable/)

## Usage

A basic usage example:

```purescript
module Main where

import Prelude
import Control.Monad.Eff.Console (log)
import Control.Monad.Eff.Exception (message)
import Control.Observable (fromFoldable, subscribe)
import Data.String (toUpper)

main = do
  let o = toUpper <$> fromFoldable ["hello", "world"]
  subscribe {
    next: log,
    error: message >>> log,
    complete: pure unit
    } o
```

Creating custom streams:

```purescript
module Main where

import Prelude
import Control.Monad.Eff.Console (log)
import Control.Monad.Eff.Exception (message)
import Control.Observable (noUnsub, observable, subscribe)

main = do
  o <- observable \sink -> do
    sink.next "Hello Joe"
    sink.next "Hello Mike"
    sink.next "Hello Robert"
    sink.complete
    noUnsub

  -- `observe` is a shorthand for `subscribe`
  observe log (message >>> log) (pure unit) o
```

## ECMAScript Observable Compatibility

The observables created by this library should be fully compatible
with the
[ECMAScript Observable proposal](https://github.com/zenparsing/es-observable).
You should also be able to consume any observable implementing the
specification using this library, if you cast it to the `Observable`
type.

## FAQ

Q: Why isn't every operation effectful?

A: Only operations which may need to utilise effects themselves are
effectful. This includes creating new observables, subscribing to an
observable, and not much else. Creating a new observable by eg.
mapping a pure function over an existing observable is itself a pure
function - it's true that if you perform such an operation twice
you'll have two different observables, but they'll always emit the
exact same events at the exact same time, meaning that they have value
equality.

## Licence

Copyright 2016 Bodil Stokke

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Lesser General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this program. If not, see
<http://www.gnu.org/licenses/>.
