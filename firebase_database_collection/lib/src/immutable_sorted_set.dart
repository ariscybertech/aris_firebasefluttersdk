// File created by
// Lung Razvan <long1eu>
// on 19/09/2018

import 'package:firebase_database_collection/src/immutable_sorted_map.dart';

class ImmutableSortedSet<T> extends Iterable<T> {
  final ImmutableSortedMap<T, void> _map;

  factory ImmutableSortedSet([List<T> elements, Comparator<T> comparator]) {
    return ImmutableSortedSet<T>._(ImmutableSortedMap.buildFrom(
      elements ?? <T>[],
      <T, void>{},
      ImmutableSortedMap.identityTranslator(),
      comparator ?? (T a, T b) => (a as Comparable<T>).compareTo(b),
    ));
  }

  ImmutableSortedSet._(this._map);

  @override
  bool contains(Object element) {
    return element is T && _map.containsKey(element);
  }

  ImmutableSortedSet<T> remove(T entry) {
    final ImmutableSortedMap<T, void> newMap = _map.remove(entry);
    return (newMap == _map) ? this : ImmutableSortedSet<T>._(newMap);
  }

  ImmutableSortedSet<T> insert(T entry) {
    return ImmutableSortedSet<T>._(_map.insert(entry, null));
  }

  T get minEntry => _map.minKey;

  T get maxEntry => _map.maxKey;

  @override
  int get length => _map.length;

  @override
  bool get isEmpty => _map.isEmpty;

  @override
  Iterator<T> get iterator => _getIterator(_map.iterator).iterator;

  Iterator<T> get reverseIterator {
    return _getIterator(_map.reverseIterator).iterator;
  }

  Iterator<T> iteratorFrom(T key) {
    return _getIterator(_map.iteratorFrom(key)).iterator;
  }

  Iterator<T> reverseIteratorFrom(T key) {
    return _getIterator(_map.reverseIteratorFrom(key)).iterator;
  }

  T getPredecessorEntry(T entry) => _map.getPredecessorKey(entry);

  int indexOf(T entry) => _map.indexOf(entry);

  Iterable<T> _getIterator(Iterator<MapEntry<T, void>> it) sync* {
    while (it.moveNext()) {
      yield it.current.key;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImmutableSortedSet &&
          runtimeType == other.runtimeType &&
          _map == other._map;

  @override
  int get hashCode => _map.hashCode;
}
