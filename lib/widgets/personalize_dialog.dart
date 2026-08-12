import 'package:flutter/material.dart';

import '../services/metrics.dart';

class PersonalizeResult {
  final double? heightInches;
  final double? weightKg;
  final UnitSystem unitSystem;
  const PersonalizeResult({
    this.heightInches,
    this.weightKg,
    required this.unitSystem,
  });
}

/// Shows a dialog to personalize height/weight and pick a display unit
/// system. Fields shown reflect whichever unit is currently selected
/// (feet/in + lbs for imperial, cm + kg for metric); toggling units
/// re-seeds the fields from the saved canonical value (inches/kg) rather
/// than trying to live-convert partially-typed input. Returns null if
/// cancelled.
Future<PersonalizeResult?> showPersonalizeDialog(
  BuildContext context, {
  required double? currentHeightInches,
  required double? currentWeightKg,
  required UnitSystem currentUnitSystem,
}) {
  return showDialog<PersonalizeResult>(
    context: context,
    builder: (context) {
      return _PersonalizeDialogContent(
        currentHeightInches: currentHeightInches,
        currentWeightKg: currentWeightKg,
        currentUnitSystem: currentUnitSystem,
      );
    },
  );
}

class _PersonalizeDialogContent extends StatefulWidget {
  final double? currentHeightInches;
  final double? currentWeightKg;
  final UnitSystem currentUnitSystem;

  const _PersonalizeDialogContent({
    required this.currentHeightInches,
    required this.currentWeightKg,
    required this.currentUnitSystem,
  });

  @override
  State<_PersonalizeDialogContent> createState() =>
      _PersonalizeDialogContentState();
}

class _PersonalizeDialogContentState
    extends State<_PersonalizeDialogContent> {
  late UnitSystem _unit;

  // Imperial fields.
  final _feetController = TextEditingController();
  final _inchesController = TextEditingController();
  final _lbsController = TextEditingController();

  // Metric fields.
  final _cmController = TextEditingController();
  final _kgController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _unit = widget.currentUnitSystem;
    _seedFieldsFromCanonical();
  }

  void _seedFieldsFromCanonical() {
    final heightInches = widget.currentHeightInches;
    final weightKg = widget.currentWeightKg;

    if (heightInches != null) {
      final feet = heightInches ~/ 12;
      final inches = (heightInches % 12).round();
      _feetController.text = feet.toString();
      _inchesController.text = inches.toString();
      _cmController.text =
          (heightInches * StepMetrics.inchesToCm).toStringAsFixed(0);
    }
    if (weightKg != null) {
      _lbsController.text =
          (weightKg * StepMetrics.kgToLbs).toStringAsFixed(0);
      _kgController.text = weightKg.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _feetController.dispose();
    _inchesController.dispose();
    _lbsController.dispose();
    _cmController.dispose();
    _kgController.dispose();
    super.dispose();
  }

  double? get _heightInches {
    if (_unit == UnitSystem.imperial) {
      final ft = int.tryParse(_feetController.text.trim());
      final inch = int.tryParse(_inchesController.text.trim());
      if (ft == null && inch == null) return null;
      final total = (ft ?? 0) * 12 + (inch ?? 0);
      return total > 0 ? total.toDouble() : null;
    } else {
      final cm = double.tryParse(_cmController.text.trim());
      if (cm == null || cm <= 0) return null;
      return cm * StepMetrics.cmToInches;
    }
  }

  double? get _weightKg {
    if (_unit == UnitSystem.imperial) {
      final lbs = double.tryParse(_lbsController.text.trim());
      if (lbs == null || lbs <= 0) return null;
      return lbs * StepMetrics.lbsToKg;
    } else {
      final kg = double.tryParse(_kgController.text.trim());
      if (kg == null || kg <= 0) return null;
      return kg;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Personalize'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Used to make Distance and Calorie estimates more accurate. '
              'Leave blank to use general averages instead.',
            ),
            const SizedBox(height: 16),
            Center(
              child: SegmentedButton<UnitSystem>(
                segments: const [
                  ButtonSegment(
                    value: UnitSystem.imperial,
                    label: Text('Imperial'),
                  ),
                  ButtonSegment(
                    value: UnitSystem.metric,
                    label: Text('Metric'),
                  ),
                ],
                selected: {_unit},
                onSelectionChanged: (selection) {
                  setState(() => _unit = selection.first);
                },
              ),
            ),
            const SizedBox(height: 16),
            Text('Height', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            if (_unit == UnitSystem.imperial)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _feetController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(suffixText: 'ft'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _inchesController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(suffixText: 'in'),
                    ),
                  ),
                ],
              )
            else
              TextField(
                controller: _cmController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(suffixText: 'cm'),
              ),
            const SizedBox(height: 16),
            Text('Weight', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            TextField(
              controller:
                  _unit == UnitSystem.imperial ? _lbsController : _kgController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                suffixText: _unit == UnitSystem.imperial ? 'lbs' : 'kg',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            PersonalizeResult(
              heightInches: null,
              weightKg: null,
              unitSystem: _unit,
            ),
          ),
          child: const Text('Use averages'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            PersonalizeResult(
              heightInches: _heightInches,
              weightKg: _weightKg,
              unitSystem: _unit,
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
