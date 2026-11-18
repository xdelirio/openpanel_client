import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// What the client keeps between launches: the install's device id and the
/// events not yet sent.
@immutable
class StoredState {
  const StoredState({required this.deviceId, required this.queue});

  final String deviceId;

  /// `/track` bodies (`{type, payload}`), oldest first.
  final List<Map<String, Object?>> queue;

  Map<String, Object?> toJson() => {'deviceId': deviceId, 'queue': queue};

  /// Null when [json] is not a state this client wrote: a store that cannot
  /// be read starts over rather than failing every launch. Items that are
  /// not events this client sends are skipped, since one malformed item
  /// would otherwise be retried forever at the head of the queue.
  static StoredState? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final deviceId = json['deviceId'];
    final queue = json['queue'];
    if (deviceId is! String || deviceId.isEmpty || queue is! List) return null;
    return StoredState(
      deviceId: deviceId,
      queue: [
        for (final item in queue)
          if (isSendable(item)) item as Map<String, Object?>,
      ],
    );
  }

  /// Whether [item] has the shape of a body the client queues.
  @visibleForTesting
  static bool isSendable(Object? item) {
    if (item is! Map<String, Object?>) return false;
    final payload = item['payload'];
    if (payload is! Map<String, Object?>) return false;
    return switch (item['type']) {
      'track' =>
        payload['name'] is String &&
            payload['properties'] is Map<String, Object?>,
      'identify' => payload['profileId'] is String,
      'increment' || 'decrement' =>
        payload['profileId'] is String &&
            payload['property'] is String &&
            payload['value'] is num,
      _ => false,
    };
  }
}

/// Where [StoredState] lives. The client serialises its calls: there is never
/// more than one [save] in flight.
abstract class QueueStore {
  /// Null on first launch, or when what was stored cannot be read as a
  /// state. Throws when the store is there but out of reach (I/O error,
  /// held by another process): the client then leaves it untouched.
  Future<StoredState?> load();

  Future<void> save(StoredState state);

  /// Releases what the store holds open. Called by the client's dispose.
  Future<void> close() async {}
}

/// Keeps the state for the life of the process only. For tests, and for
/// platforms with no file system (web).
class MemoryQueueStore extends QueueStore {
  MemoryQueueStore([this.state]);

  StoredState? state;

  @override
  Future<StoredState?> load() async => state;

  @override
  Future<void> save(StoredState state) async => this.state = state;
}

/// Thrown by [FileQueueStore.load] when another process holds the store.
class StoreLockedException implements Exception {
  const StoreLockedException(this.path, {this.deviceId});

  final String path;

  /// The install's id as the store holds it, read without the lock, so the
  /// second instance still reports as the same install.
  final String? deviceId;

  @override
  String toString() =>
      'StoreLockedException: $path is in use by another '
      'process';
}

/// Keeps the state in one JSON file, so queued events survive a restart.
///
/// Written to a sibling and renamed over the original: a process killed
/// mid-write leaves the previous file whole instead of a truncated one.
///
/// Held with a lock file for as long as the client runs: two instances of a
/// desktop app would otherwise overwrite each other's queue and both send
/// what the last run left. The second one gets [StoreLockedException] and
/// keeps its events in memory.
class FileQueueStore extends QueueStore {
  FileQueueStore(this.file);

  final File file;
  RandomAccessFile? _lock;

  /// Paths held by a store of this process. OS file locks are per process
  /// on POSIX: a second store here would take the same lock without error,
  /// and releasing the first would release the second's.
  static final _heldHere = <String>{};

  @override
  Future<StoredState?> load() async {
    final path = file.absolute.path;
    if (_heldHere.contains(path)) {
      throw StoreLockedException(path, deviceId: await _peekDeviceId());
    }
    await file.parent.create(recursive: true);
    final lock = await File('$path.lock').open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      throw StoreLockedException(path, deviceId: await _peekDeviceId());
    }
    _lock = lock;
    _heldHere.add(path);
    return _read();
  }

  /// The stored state; null when there is none or it is not one. An I/O
  /// error propagates: the file may be whole, just out of reach right now,
  /// and must not be taken for a first launch.
  Future<StoredState?> _read() async {
    // `exists()` is false for a directory or anything else in the way; only
    // a path with nothing at it is a first launch.
    if (await FileSystemEntity.type(file.path) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    final bytes = await file.readAsBytes();
    try {
      return StoredState.tryParse(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      // Not UTF-8 or not JSON: corrupt, so it starts over.
      return null;
    }
  }

  Future<String?> _peekDeviceId() async {
    try {
      return (await _read())?.deviceId;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(StoredState state) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> close() async {
    final lock = _lock;
    _lock = null;
    if (lock == null) return;
    _heldHere.remove(file.absolute.path);
    try {
      await lock.unlock();
    } finally {
      await lock.close();
    }
  }
}
