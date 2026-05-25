import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_eeg_desktop/src/app.dart';

void main() {
  testWidgets('renders the sleep EEG viewer shell', (tester) async {
    await tester.pumpWidget(const SleepEegApp());

    expect(find.text('Epoch:'), findsOneWidget);
    expect(find.textContaining('Ready'), findsOneWidget);
  });
}
