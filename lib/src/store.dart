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
  /// be read starts over rather than failing every launch.
  static StoredState? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final deviceId = json['deviceId'];
    final queue = json['queue'];
    if (deviceId is! String || deviceId.isEmpty || queue is! List) return null;
    return StoredState(
      deviceId: deviceId,
      queue: [
        for (final item in queue)
          if (item is Map<String, Object?>) item,
      ],
    );
  }
}

/// Where [StoredState] lives. The client serialises its calls: there is never
/// more than one [save] in flight.
abstract interface class QueueStore {
  /// Null on first launch, or when what was stored cannot be read.
  Future<StoredState?> load();

  Future<void> save(StoredState state);
}

/// Keeps the state for the life of the process only. For tests, and for
/// platforms with no file system (web).
class MemoryQueueStore implements QueueStore {
  MemoryQueueStore([this.state]);

  StoredState? state;

  @override
  Future<StoredState?> load() async => state;

  @override
  Future<void> save(StoredState state) async => this.state = state;
}

/// Keeps the state in one JSON file, so queued events survive a restart.
///
/// Written to a sibling and renamed over the original: a process killed
/// mid-write leaves the previous file whole instead of a truncated one.
class FileQueueStore implements QueueStore {
  FileQueueStore(this.file);

  final File file;

  @override
  Future<StoredState?> load() async {
    try {
      if (!await file.exists()) return null;
      return StoredState.tryParse(jsonDecode(await file.readAsString()));
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
}
