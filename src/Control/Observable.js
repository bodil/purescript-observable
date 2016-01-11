"use strict";

var _createClass = function () { function defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } } return function (Constructor, protoProps, staticProps) { if (protoProps) defineProperties(Constructor.prototype, protoProps); if (staticProps) defineProperties(Constructor, staticProps); return Constructor; }; }();

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

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

var Observable = function () {
  function Observable(subscriber) {
    var _this = this;

    _classCallCheck(this, Observable);

    this.observers = {};
    this.count = 0;
    this.uid = 0;
    this.subscriber = subscriber;
    this.sinkSubscription = null;
    this.complete = false;
    this.failed = null;
    this.sink = {
      next: function next(v) {
        if (_this.complete) {
          throw new Error("cannot feed values into a closed Observable");
        } else {
          _this.forEachObserver(function (o) {
            return schedule(function () {
              return o.next && o.next(v);
            });
          });
        }
      },
      error: function error(e) {
        if (_this.complete) {
          throw e;
        }
        _this.forEachObserver(function (o) {
          return schedule(function () {
            return o.error && o.error(e);
          });
        });
        _this.failed = e;
        _this.close();
      },
      complete: function complete(v) {
        if (_this.complete) {
          throw new Error("cannot complete an already closed Observable");
        }
        _this.forEachObserver(function (o) {
          return schedule(function () {
            return o.complete && o.complete(v);
          });
        });
        _this.close();
      }
    };
  }

  _createClass(Observable, [{
    key: "forEachObserver",
    value: function forEachObserver(f) {
      var _this2 = this;

      Object.keys(this.observers).forEach(function (k) {
        return f(_this2.observers[k]);
      });
    }
  }, {
    key: "subscribe",
    value: function subscribe(observer) {
      var _this3 = this;

      var uid = this.uid++;
      this.observers[uid] = observer;
      this.incObservers();
      return {
        unsubscribe: function unsubscribe() {
          delete _this3.observers[uid];
          _this3.decObservers();
        }
      };
    }
  }, {
    key: "forEach",
    value: function forEach(cb) {
      var _this4 = this;

      return new Promise(function (resolve, reject) {
        _this4.subscribe({
          next: function next(v) {
            try {
              return cb(v);
            } catch (e) {
              reject(e);
            }
          },
          error: reject,
          complete: resolve
        });
      });
    }
  }, {
    key: "startSubscription",
    value: function startSubscription() {
      if (this.sinkSubscription === null) {
        this.sinkSubscription = this.subscriber(this.sink);
      }
    }
  }, {
    key: "endSubscription",
    value: function endSubscription() {
      if (this.sinkSubscription) {
        this.sinkSubscription.unsubscribe();
        this.sinkSubscription = null;
      }
    }
  }, {
    key: "close",
    value: function close() {
      this.endSubscription();
      this.complete = true;
      this.observers = {};
    }
  }, {
    key: "incObservers",
    value: function incObservers() {
      if (this.count == 0) {
        this.startSubscription();
      }
      this.count++;
    }
  }, {
    key: "decObservers",
    value: function decObservers() {
      this.count--;
      if (this.count === 0) {
        this.endSubscription();
      }
    }
  }]);

  return Observable;
}();

exports.empty = {
  subscribe: function subscribe(obs) {
    obs.complete();
    return { unsubscribe: function unsubscribe() {} };
  }
};

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
        complete: sink.complete
      })();
    });
  };
};

exports.subscribe = function (observer) {
  return function (observable) {
    return function () {
      return observable.subscribe({
        next: function next(v) {
          return observer.next(v)();
        },
        error: function error(e) {
          return observer.error(e)();
        },
        complete: observer.complete
      });
    };
  };
};