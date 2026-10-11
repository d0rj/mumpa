/// A public artist recommendation identified by its MusicBrainz artist ID.
///
/// [score] is a ListenBrainz co-listening score, not a similarity percentage.
class SimilarArtist {
  const SimilarArtist({
    required this.id,
    required this.name,
    required this.score,
    this.disambiguation = '',
    this.type = '',
  });

  final String id, name, disambiguation, type;
  final int score;
}
