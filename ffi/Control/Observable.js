// module Control.Observable

const scheduler = {
  queue: [],
  scheduled: false,
  next: typeof global !== "undefined" && typeof process !== "undefined" ? global.setImmediate || process.nextTick : (f) => setTimeout(f, 0)
};

function runScheduler() {
  const queue = scheduler.queue;
  scheduler.queue = [];
  scheduler.scheduled = false;
  queue.forEach((f) => f());
}

function schedule(f) {
  scheduler.queue.push(f);
  if (!scheduler.scheduled) {
    scheduler.scheduled = true;
    scheduler.next(runScheduler);
  }
}

class Observable {
  constructor(subscriber) {
    this.observers = {};
    this.count = 0;
    this.uid = 0;
    this.subscriber = subscriber;
    this.sinkSubscription = null;
    this.complete = false;
    this.failed = null;
    this.sink = {
      next: (v) => {
        if (this.complete) {
          throw new Error("cannot feed values into a closed Observable");
        } else {
          this.forEachObserver((o) => schedule(() => o.next && o.next(v)));
        }
      },
      error: (e) => {
        if (this.complete) {
          throw e;
        }
        this.forEachObserver((o) => schedule(() => o.error && o.error(e)));
        this.failed = e;
        this.close();
      },
      complete: (v) => {
        if (this.complete) {
          throw new Error("cannot complete an already closed Observable");
        }
        this.forEachObserver((o) => schedule(() => o.complete && o.complete(v)));
        this.close();
      }
    };
  }

  forEachObserver(f) {
    Object.keys(this.observers).forEach((k) => f(this.observers[k]));
  }

  subscribe(observer) {
    const uid = this.uid++;
    this.observers[uid] = observer;
    this.incObservers();
    return {
      unsubscribe: () => {
        delete this.observers[uid];
        this.decObservers();
      }
    };
  }

  forEach(cb) {
    return new Promise((resolve, reject) => {
      this.subscribe({
        next: (v) => {
          try { return cb(v); } catch (e) { reject(e); }
        },
        error: reject,
        complete: resolve
      });
    });
  }

  startSubscription() {
    if (this.sinkSubscription === null) {
      this.sinkSubscription = this.subscriber(this.sink);
    }
  }

  endSubscription() {
    if (this.sinkSubscription) {
      this.sinkSubscription.unsubscribe();
      this.sinkSubscription = null;
    }
  }

  close() {
    this.endSubscription();
    this.complete = true;
    this.observers = {};
  }

  incObservers() {
    if (this.count == 0) {
      this.startSubscription();
    }
    this.count++;
  }

  decObservers() {
    this.count--;
    if (this.count === 0) {
      this.endSubscription();
    }
  }
}

exports.empty = {
  subscribe(obs) {
    obs.complete();
    return {unsubscribe: () => {}};
  }
};

exports.observable = (subscriber) => () => new Observable((sink) => subscriber({
  next: (v) => () => sink.next(v),
  error: (e) => () => sink.error(e),
  complete: sink.complete
})());

exports.subscribe = (observer) => (observable) => () => observable.subscribe({
  next: (v) => observer.next(v)(),
  error: (e) => observer.error(e)(),
  complete: observer.complete
});
