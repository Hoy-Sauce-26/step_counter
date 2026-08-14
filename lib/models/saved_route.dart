/// A saved, named walking circuit, with its rough step estimate averaged
/// from past sessions. [avgSteps] and [sessionCount] come from an
/// aggregate query — see DatabaseHelper.getRoutes.
class SavedRoute {
  final int id;
  final String name;
  final double? avgSteps; // null if never walked yet
  final int sessionCount;

  const SavedRoute({
    required this.id,
    required this.name,
    required this.avgSteps,
    required this.sessionCount,
  });
}
