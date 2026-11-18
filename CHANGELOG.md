## 0.2.0

- Sends never stall the queue: the `User-Agent` is ASCII (an accented app
  name made every request fail before leaving), and only network errors are
  retried — anything else drops the event.
- A 401 for the event (project filter, revenue) is final; a 401 for the
  client still pauses the queue.
- Timed-out requests are aborted, and a send that hangs anyway is cut off
  by a backstop; `dispose` lets the request in flight finish instead of
  aborting it. Delivery is at-least-once: a request the server took but
  whose answer was lost is sent again.
- `__timestamp` only on events over a minute old, corrected with the
  server's `Date`: a device with a wrong clock no longer loses sessions.
- Stored items are validated on load; a store out of reach is left alone
  (no overwrite), and one held by another instance still gives its device
  id. `FileQueueStore` holds a lock file, and refuses a second store on the
  same file within one process too. A file that is not UTF-8 starts over.
- `persist()` writes at once; `OpenPanelLifecycle` calls it on hide.
- `__timestamp` recorded before 2024 (a clock not set yet) is left out.
- Client-side checks for what the server refuses (names, empty profile id,
  counters ≤ 0, invalid email/avatar); a throwing logger is contained.
- Store writes debounced (`persistDelay`); macOS user agent the server
  parses; brand casing and Windows 11 in device detection.
- `QueueStore` is now an abstract class with `close()`. Requires
  `http` 1.5 (abortable requests).

## 0.1.0

- First version: `OpenPanel` (track, screen, identify, reset, increment,
  decrement, global properties, opt-out), ordered persistent queue with
  backoff, `FileQueueStore` / `MemoryQueueStore`, `detectDeviceContext`,
  `OpenPanelObserver`, `OpenPanelLifecycle` and `FakeOpenPanel`.
