/// A saved route, with a rough step estimate averaged from past sessions —
/// see DatabaseHelper.getRoutes.
class SavedRoute {
  final int id;
  final String name;
  final double? avgSteps; // null if no sessions yet

  const SavedRoute({
    required this.id,
    required this.name,
    required this.avgSteps,
  });
}
