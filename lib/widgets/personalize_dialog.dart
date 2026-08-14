import 'package:flutter/material.dart';

import '../services/metrics.dart';

class PersonalizeResult {
  final double? heightCm;
  final double? weightKg;
  final UnitSystem unitSystem;
  const PersonalizeResult({
    this.heightCm,
    this.weightKg,
    required this.unitSystem,
  });
}

/// Dialog to personalize height/weight and pick a unit system. Shows
/// feet/in + lbs for imperial, cm + kg for metric; toggling units re-seeds
/// from the saved canonical value rather than live-converting typed
/// input. Returns null if cancelled.
Future<PersonalizeResult?> showPersonalizeDialog(
  BuildContext context, {
  required double? currentHeightCm,
  required double? currentWeightKg,
  required UnitSystem currentUnitSystem,
}) {
  return showDialog<PersonalizeResult>(
    context: context,
    builder: (context) {
      return _PersonalizeDialogContent(
        currentHeightCm: currentHeightCm,
        currentWeightKg: currentWeightKg,
        currentUnitSystem: currentUnitSystem,
      );
    },
  );
}

class _PersonalizeDialogContent extends StatefulWidget {
  final double? currentHeightCm;
  final double? currentWeightKg;
  final UnitSystem currentUnitSystem;

  const _PersonalizeDialogContent({
    required this.currentHeightCm,
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
    final heightCm = widget.currentHeightCm;
    final weightKg = widget.currentWeightKg;

    if (heightCm != null) {
      _cmController.text = heightCm.toStringAsFixed(0);
      final feet = (heightCm * StepMetrics.cmToInches) ~/ 12;
      final inches = ((heightCm * StepMetrics.cmToInches) % 12).round();
      _feetController.text = feet.toString();
      _inchesController.text = inches.toString();
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

  double? get _heightCm {
    if (_unit == UnitSystem.metric) {
      final cm = double.tryParse(_cmController.text.trim());
      if (cm == null || cm <= 0) return null;
      return cm;
    } else {
      final ft = int.tryParse(_feetController.text.trim());
      final inch = int.tryParse(_inchesController.text.trim());
      if (ft == null && inch == null) return null;
      final total = ((ft ?? 0) * 12) + (inch ?? 0);
      return total > 0 ? total.toDouble() * StepMetrics.inchesToCm : null;
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
              heightCm: null,
              weightKg: null,
              unitSystem: _unit,
            ),
          ),
          child: const Text('Use averages'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            PersonalizeResult(
              heightCm: _heightCm,
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
