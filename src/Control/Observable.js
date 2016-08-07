"use strict";

var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function (obj) { return typeof obj; } : function (obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol ? "symbol" : typeof obj; };

// module Control.Observable

var scheduler = {
  queue: [],
  scheduled: false,
  next: typeof global !== "undefined" && typeof process !== "undefined" ? global.setImmediate || process.nextTick : function (f) {
    return setTimeout(f, 0);
  }
};

function runScheduler() {
  var queue = scheduler.queue;
  scheduler.queue = [];
  scheduler.scheduled = false;
  queue.forEach(function (f) {
    return f();
  });
}

function schedule(f) {
  scheduler.queue.push(f);
  if (!scheduler.scheduled) {
    scheduler.scheduled = true;
    scheduler.next(runScheduler);
  }
}
exports.schedule = function (f) {
  return function () {
    return schedule(f);
  };
};

/// Here follows an inline embedding of the zen-observable package,
/// which is Copyright (c) 2015 zenparsing (Kevin Smith) and licensed
/// under the MIT licence.
///
/// It is, essentially, the reference implementation for ECMAScript
/// observables.
///
/// It can be found at https://github.com/zenparsing/zen-observable
///
/// Note that I've removed all the extraneous methods on `Observable`
/// (the ones which are absent from the current proposal spec) with
/// the exception of `flatMap`, which I've kept on the assumption
/// that it's considerably more performant than the PS equivalent.

// === Symbol Support ===

function hasSymbol(name) {

  return typeof Symbol === "function" && Boolean(Symbol[name]);
}

function getSymbol(name) {

  return hasSymbol(name) ? Symbol[name] : "@@" + name;
}

// === Abstract Operations ===

function getMethod(obj, key) {

  var value = obj[key];

  if (value == null) return undefined;

  if (typeof value !== "function") throw new TypeError(value + " is not a function");

  return value;
}

function getSpecies(ctor) {

  var symbol = getSymbol("species");
  return symbol ? ctor[symbol] : ctor;
}

function addMethods(target, methods) {

  Object.keys(methods).forEach(function (k) {

    var desc = Object.getOwnPropertyDescriptor(methods, k);
    desc.enumerable = false;
    Object.defineProperty(target, k, desc);
  });
}

function cleanupSubscription(subscription) {

  // Assert:  observer._observer is undefined

  var cleanup = subscription._cleanup;

  if (!cleanup) return;

  // Drop the reference to the cleanup function so that we won't call it
  // more than once
  subscription._cleanup = undefined;

  // Call the cleanup function
  cleanup();
}

function subscriptionClosed(subscription) {

  return subscription._observer === undefined;
}

function closeSubscription(subscription) {

  if (subscriptionClosed(subscription)) return;

  subscription._observer = undefined;
  cleanupSubscription(subscription);
}

function cleanupFromSubscription(subscription) {
  return function (_) {
    subscription.unsubscribe();
  };
}

function Subscription(observer, subscriber) {

  // Assert: subscriber is callable

  // The observer must be an object
  if (Object(observer) !== observer) throw new TypeError("Observer must be an object");

  this._cleanup = undefined;
  this._observer = observer;

  var start = getMethod(observer, "start");

  if (start) start.call(observer, this);

  if (subscriptionClosed(this)) return;

  observer = new SubscriptionObserver(this);

  try {

    // Call the subscriber function
    var cleanup = subscriber.call(undefined, observer);

    // The return value must be undefined, null, a subscription object, or a function
    if (cleanup != null) {

      if (typeof cleanup.unsubscribe === "function") cleanup = cleanupFromSubscription(cleanup);else if (typeof cleanup !== "function") throw new TypeError(cleanup + " is not a function");

      this._cleanup = cleanup;
    }
  } catch (e) {

    // If an error occurs during startup, then attempt to send the error
    // to the observer
    observer.error(e);
    return;
  }

  // If the stream is already finished, then perform cleanup
  if (subscriptionClosed(this)) cleanupSubscription(this);
}

addMethods(Subscription.prototype = {}, {
  get closed() {
    return subscriptionClosed(this);
  },
  unsubscribe: function unsubscribe() {
    closeSubscription(this);
  }
});

function SubscriptionObserver(subscription) {
  this._subscription = subscription;
}

addMethods(SubscriptionObserver.prototype = {}, {

  get closed() {
    return subscriptionClosed(this._subscription);
  },

  next: function next(value) {

    var subscription = this._subscription;

    // If the stream if closed, then return undefined
    if (subscriptionClosed(subscription)) return undefined;

    var observer = subscription._observer;

    try {

      var m = getMethod(observer, "next");

      // If the observer doesn't support "next", then return undefined
      if (!m) return undefined;

      // Send the next value to the sink
      return m.call(observer, value);
    } catch (e) {

      // If the observer throws, then close the stream and rethrow the error
      try {
        closeSubscription(subscription);
      } finally {
        throw e;
      }
    }
  },
  error: function error(value) {

    var subscription = this._subscription;

    // If the stream is closed, throw the error to the caller
    if (subscriptionClosed(subscription)) throw value;

    var observer = subscription._observer;
    subscription._observer = undefined;

    try {

      var m = getMethod(observer, "error");

      // If the sink does not support "error", then throw the error to the caller
      if (!m) throw value;

      value = m.call(observer, value);
    } catch (e) {

      try {
        cleanupSubscription(subscription);
      } finally {
        throw e;
      }
    }

    cleanupSubscription(subscription);
    return value;
  },
  complete: function complete(value) {

    var subscription = this._subscription;

    // If the stream is closed, then return undefined
    if (subscriptionClosed(subscription)) return undefined;

    var observer = subscription._observer;
    subscription._observer = undefined;

    try {

      var m = getMethod(observer, "complete");

      // If the sink does not support "complete", then return undefined
      value = m ? m.call(observer, value) : undefined;
    } catch (e) {

      try {
        cleanupSubscription(subscription);
      } finally {
        throw e;
      }
    }

    cleanupSubscription(subscription);
    return value;
  }
});

function Observable(subscriber) {

  // The stream subscriber must be a function
  if (typeof subscriber !== "function") throw new TypeError("Observable initializer must be a function");

  this._subscriber = subscriber;
}

addMethods(Observable.prototype, {
  subscribe: function subscribe(observer) {

    if (typeof observer === 'function') {

      observer = {
        next: observer,
        error: arguments.length <= 1 ? undefined : arguments[1],
        complete: arguments.length <= 2 ? undefined : arguments[2]
      };
    }

    return new Subscription(observer, this._subscriber);
  },
  forEach: function forEach(fn) {
    var _this = this;

    return new Promise(function (resolve, reject) {

      if (typeof fn !== "function") return Promise.reject(new TypeError(fn + " is not a function"));

      _this.subscribe({

        _subscription: null,

        start: function start(subscription) {

          if (Object(subscription) !== subscription) throw new TypeError(subscription + " is not an object");

          this._subscription = subscription;
        },
        next: function next(value) {

          var subscription = this._subscription;

          if (subscription.closed) return;

          try {

            return fn(value);
          } catch (err) {

            reject(err);
            subscription.unsubscribe();
          }
        },


        error: reject,
        complete: resolve
      });
    });
  },
  flatMap: function flatMap(fn) {
    var _this2 = this;

    if (typeof fn !== "function") throw new TypeError(fn + " is not a function");

    var C = getSpecies(this.constructor);

    return new C(function (observer) {

      var completed = false,
          subscriptions = [];

      // Subscribe to the outer Observable
      var outer = _this2.subscribe({
        next: function next(value) {

          if (fn) {

            try {

              value = fn(value);
            } catch (x) {

              observer.error(x);
              return;
            }
          }

          // Subscribe to the inner Observable
          Observable.from(value).subscribe({

            _subscription: null,

            start: function start(s) {
              subscriptions.push(this._subscription = s);
            },
            next: function next(value) {
              observer.next(value);
            },
            error: function error(e) {
              observer.error(e);
            },
            complete: function complete() {

              var i = subscriptions.indexOf(this._subscription);

              if (i >= 0) subscriptions.splice(i, 1);

              closeIfDone();
            }
          });
        },
        error: function error(e) {

          return observer.error(e);
        },
        complete: function complete() {

          completed = true;
          closeIfDone();
        }
      });

      function closeIfDone() {

        if (completed && subscriptions.length === 0) observer.complete();
      }

      return function (_) {

        subscriptions.forEach(function (s) {
          return s.unsubscribe();
        });
        outer.unsubscribe();
      };
    });
  }
});

Object.defineProperty(Observable.prototype, getSymbol("observable"), {
  value: function value() {
    return this;
  },
  writable: true,
  configurable: true
});

addMethods(Observable, {
  from: function from(x) {

    var C = typeof this === "function" ? this : Observable;

    if (x == null) throw new TypeError(x + " is not an object");

    var method = getMethod(x, getSymbol("observable"));

    if (method) {
      var _ret = function () {

        var observable = method.call(x);

        if (Object(observable) !== observable) throw new TypeError(observable + " is not an object");

        if (observable.constructor === C) return {
            v: observable
          };

        return {
          v: new C(function (observer) {
            return observable.subscribe(observer);
          })
        };
      }();

      if ((typeof _ret === "undefined" ? "undefined" : _typeof(_ret)) === "object") return _ret.v;
    }

    if (hasSymbol("iterator") && (method = getMethod(x, getSymbol("iterator")))) {

      return new C(function (observer) {
        var _iteratorNormalCompletion = true;
        var _didIteratorError = false;
        var _iteratorError = undefined;

        try {

          for (var _iterator = method.call(x)[Symbol.iterator](), _step; !(_iteratorNormalCompletion = (_step = _iterator.next()).done); _iteratorNormalCompletion = true) {
            var item = _step.value;


            observer.next(item);

            if (observer.closed) return;
          }
        } catch (err) {
          _didIteratorError = true;
          _iteratorError = err;
        } finally {
          try {
            if (!_iteratorNormalCompletion && _iterator.return) {
              _iterator.return();
            }
          } finally {
            if (_didIteratorError) {
              throw _iteratorError;
            }
          }
        }

        observer.complete();
      });
    }

    if (Array.isArray(x)) {

      return new C(function (observer) {

        for (var i = 0; i < x.length; ++i) {

          observer.next(x[i]);

          if (observer.closed) return;
        }

        observer.complete();
      });
    }

    throw new TypeError(x + " is not observable");
  },
  of: function of() {
    for (var _len = arguments.length, items = Array(_len), _key = 0; _key < _len; _key++) {
      items[_key] = arguments[_key];
    }

    var C = typeof this === "function" ? this : Observable;

    return new C(function (observer) {

      for (var i = 0; i < items.length; ++i) {

        observer.next(items[i]);

        if (observer.closed) return;
      }

      observer.complete();
    });
  }
});

Object.defineProperty(Observable, getSymbol("species"), {
  get: function get() {
    return this;
  },

  configurable: true
});

/// Here follows the PureScript FFI wrappers for ES observables.

exports.observable = function (subscriber) {
  return function () {
    return new Observable(function (sink) {
      return subscriber({
        next: function next(v) {
          return function () {
            return sink.next(v);
          };
        },
        error: function error(e) {
          return function () {
            return sink.error(e);
          };
        },
        complete: function complete() {
          return sink.complete();
        }
      })();
    });
  };
};

function wrapSub(sub) {
  return { unsubscribe: function unsubscribe() {
      return sub.unsubscribe();
    } };
}

exports.subscribe = function (observer) {
  return function (observable) {
    return function () {
      return wrapSub(observable.subscribe({
        next: function next(v) {
          return observer.next(v)();
        },
        error: function error(e) {
          return observer.error(e)();
        },
        complete: function complete() {
          return observer.complete();
        }
      }));
    };
  };
};

exports._bind = function (observable) {
  return function (fn) {
    return observable.flatMap(fn);
  };
};