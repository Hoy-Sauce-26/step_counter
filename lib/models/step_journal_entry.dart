/// One journalled reading of the hardware step counter.
///
/// [rawSteps] is cumulative since the counter last reset, which is device
/// boot — never a delta. [at] is when the reading was taken.
class StepJournalEntry {
  final DateTime at;
  final int rawSteps;

  const StepJournalEntry({required this.at, required this.rawSteps});

  Map<String, Object?> toMap() => {
        'recordedAt': at.millisecondsSinceEpoch,
        'rawSteps': rawSteps,
      };

  factory StepJournalEntry.fromMap(Map<String, Object?> map) => StepJournalEntry(
        at: DateTime.fromMillisecondsSinceEpoch(map['recordedAt'] as int),
        rawSteps: map['rawSteps'] as int,
      );

  @override
  String toString() => 'StepJournalEntry($rawSteps @ $at)';
}
