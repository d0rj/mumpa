import 'package:integration_test/integration_test.dart';
import '../test/search_responsiveness_test.dart' as checks;

class _TypingBinding extends IntegrationTestWidgetsFlutterBinding {
  @override
  bool get registerTestTextInput => true;
}

void main() {
  _TypingBinding();
  if (const bool.fromEnvironment('REAL_SEARCH_RESPONSIVENESS_TEST')) {
    checks.runSearchResponsivenessTests(real: true);
  }
}
