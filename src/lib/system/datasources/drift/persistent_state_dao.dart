import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../constants.dart';
import '../../../domain/entities/loop_mode.dart';
import '../../../domain/entities/playable.dart';
import '../../../domain/entities/shuffle_mode.dart';
import '../../models/album_model.dart';
import '../../models/artist_model.dart';
import '../../models/loop_mode_model.dart';
import '../../models/playlist_model.dart';
import '../../models/queue_item_model.dart';
import '../../models/shuffle_mode_model.dart';
import '../../models/smart_list_model.dart';
import '../../models/song_model.dart';
import '../drift_database.dart';
import '../persistent_state_data_source.dart';

part 'persistent_state_dao.g.dart';

@DriftAccessor(tables: [
  Albums,
  Artists,
  Songs,
  Playlists,
  PlaylistEntries,
  SmartLists,
  SmartListArtists,
  QueueEntries,
  AvailableSongEntries,
  KeyValueEntries,
])
class PersistentStateDao extends DatabaseAccessor<MainDatabase>
    with _$PersistentStateDaoMixin
    implements PersistentStateDataSource {
  PersistentStateDao(MainDatabase db) : super(db);

  @override
  Future<List<QueueItemModel>> get queueItems async {
    final query = (select(queueEntries)..orderBy([(t) => OrderingTerm(expression: t.index)]))
        .join([innerJoin(songs, songs.path.equalsExp(queueEntries.path))]);

    return await query.get().then((rows) => rows.map((row) {
          return QueueItemModel(
            SongModel.fromDrift(row.readTable(songs)),
            originalIndex: row.readTable(queueEntries).originalIndex,
            source: row.readTable(queueEntries).type.toQueueItemType(),
            isAvailable: row.readTable(queueEntries).isAvailable,
          );
        }).toList());
  }

  @override
  Future<void> setQueueItems(List<QueueItemModel> queue) async {
    final _queueEntries = <Insertable<DriftQueueEntry>>[];

    for (var i = 0; i < queue.length; i++) {
      _queueEntries.add(QueueEntriesCompanion(
        index: Value(i),
        path: Value(queue[i].song.path),
        originalIndex: Value(queue[i].originalIndex),
        type: Value(queue[i].source.toInt()),
        isAvailable: Value(queue[i].isAvailable),
      ));
    }

    await transaction(() async {
      await delete(queueEntries).go();
      await batch((batch) {
        batch.insertAll(queueEntries, _queueEntries);
      });
    });
  }

  @override
  Future<List<QueueItemModel>> get availableSongs async {
    final query = (select(availableSongEntries)
          ..orderBy([(t) => OrderingTerm(expression: t.index)]))
        .join([innerJoin(songs, songs.path.equalsExp(availableSongEntries.path))]);

    return await query.get().then((rows) => rows.map((row) {
          return QueueItemModel(
            SongModel.fromDrift(row.readTable(songs)),
            originalIndex: row.readTable(availableSongEntries).originalIndex,
            source: row.readTable(availableSongEntries).type.toQueueItemType(),
            isAvailable: row.readTable(availableSongEntries).isAvailable,
          );
        }).toList());
  }

  @override
  Future<void> setAvailableSongs(List<QueueItemModel> songs) async {
    final _songEntries = <Insertable<AvailableSongEntry>>[];

    for (var i = 0; i < songs.length; i++) {
      _songEntries.add(AvailableSongEntriesCompanion(
        index: Value(i),
        path: Value(songs[i].song.path),
        originalIndex: Value(songs[i].originalIndex),
        type: Value(songs[i].source.toInt()),
        isAvailable: Value(songs[i].isAvailable),
      ));
    }
    await transaction(() async {
      await delete(availableSongEntries).go();
      await batch((batch) {
        batch.insertAll(availableSongEntries, _songEntries);
      });
    });
  }

  @override
  Future<int?> get currentIndex async {
    return await (select(keyValueEntries)..where((tbl) => tbl.key.equals(PERSISTENT_INDEX)))
        .getSingle()
        .then((event) => event.value != null.toString() ? int.parse(event.value) : null);
  }

  @override
  Future<void> setCurrentIndex(int? index) async {
    await (update(keyValueEntries)..where((tbl) => tbl.key.equals(PERSISTENT_INDEX)))
        .write(KeyValueEntriesCompanion(value: Value(index.toString())));
  }

  @override
  Future<LoopMode> get loopMode async {
    return await (select(keyValueEntries)..where((tbl) => tbl.key.equals(PERSISTENT_LOOPMODE)))
        .getSingle()
        .then((event) => int.parse(event.value).toLoopMode());
  }

  @override
  Future<void> setLoopMode(LoopMode loopMode) async {
    await (update(keyValueEntries)..where((tbl) => tbl.key.equals(PERSISTENT_LOOPMODE)))
        .write(KeyValueEntriesCompanion(value: Value(loopMode.toInt().toString())));
  }

  @override
  Future<void> setShuffleMode(ShuffleMode shuffleMode) async {
    await (update(keyValueEntries)..where((tbl) => tbl.key.equals(PERSISTENT_SHUFFLEMODE)))
        .write(KeyValueEntriesCompanion(value: Value(shuffleMode.toInt().toString())));
  }

  @override
  Future<ShuffleMode> get shuffleMode async {
    return await (select(keyValueEntries)..where((tbl) => tbl.key.equals(PERSISTENT_SHUFFLEMODE)))
        .getSingle()
        .then((event) => int.parse(event.value).toShuffleMode());
  }

  @override
  Future<Playable> get playable async {
    final entry = await (select(keyValueEntries)
          ..where((tbl) => tbl.key.equals(PERSISTENT_PLAYABLE)))
        .getSingleOrNull();
    if (entry == null) return AllSongs();

    final data = jsonDecode(entry.value);
    final playableType = (data['type'] as String).toPlayableType();

    Playable? result;

    switch (playableType) {
      case PlayableType.all:
        result = AllSongs();
        break;
      case PlayableType.album:
        result = await (select(albums)
              ..where((tbl) => tbl.id.equals(int.parse(data['id'] as String))))
            .getSingleOrNull()
            .then((value) => value == null ? null : AlbumModel.fromDrift(value));
        break;
      case PlayableType.artist:
        result = await (select(artists)..where((tbl) => tbl.name.equals(data['id'] as String)))
            .getSingleOrNull()
            .then((value) => value == null ? null : ArtistModel.fromDrift(value));
        break;
      case PlayableType.playlist:
        final plId = int.parse(data['id'] as String);
        // TODO: need proper getter for this
        final driftPl =
            await (select(playlists)..where((tbl) => tbl.id.equals(plId))).getSingleOrNull();
        result = driftPl == null ? null : PlaylistModel.fromDrift(driftPl);
        break;
      case PlayableType.smartlist:
        final slId = int.parse(data['id'] as String);
        final sl =
            await (select(smartLists)..where((tbl) => tbl.id.equals(slId))).getSingleOrNull();

        if (sl == null)
          result = null;
        else {
          final slArtists =
              await (select(smartListArtists)..where((tbl) => tbl.smartListId.equals(slId))).join(
            [innerJoin(artists, artists.name.equalsExp(smartListArtists.artistName))],
          ).map((p0) => p0.readTable(artists)).get();

          result = SmartListModel.fromDrift(sl, slArtists);
        }
        break;
      case PlayableType.search:
        result = SearchQuery(data['id'] as String);
        break;
    }

    if (result == null) {
      return AllSongs();
    }
    return result;
  }

  @override
  Future<void> setPlayable(Playable playable) async {
    String id = '';
    switch (playable.type) {
      case PlayableType.all:
        break;
      case PlayableType.album:
        id = (playable as AlbumModel).id.toString();
        break;
      case PlayableType.artist:
        id = (playable as ArtistModel).name;
        break;
      case PlayableType.playlist:
        id = (playable as PlaylistModel).id.toString();
        break;
      case PlayableType.smartlist:
        id = (playable as SmartListModel).id.toString();
        break;
      case PlayableType.search:
        id = (playable as SearchQuery).query;
        break;
    }
    final data = {
      'id': id,
      'type': playable.type.toString(),
    };

    (update(keyValueEntries)..where((tbl) => tbl.key.equals(PERSISTENT_PLAYABLE)))
        .write(KeyValueEntriesCompanion(value: Value(jsonEncode(data))));
  }

  @override
  Future<bool> get isInitialized async =>
      await (select(keyValueEntries)..where((tbl) => tbl.key.equals(INITIALIZED)))
          .getSingle()
          .then((event) => event.value == 'true');

  @override
  Future<void> setInitialized() async {
    await (update(keyValueEntries)..where((tbl) => tbl.key.equals(INITIALIZED)))
        .write(const KeyValueEntriesCompanion(value: Value('true')));
  }
}
