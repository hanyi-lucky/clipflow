import 'package:flutter/material.dart';
import 'app.dart';
import 'providers/auth_provider.dart';
import 'providers/clipboard_provider.dart';
import 'providers/settings_provider.dart';
import 'package:provider/provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => ClipboardProvider()),
      ],
      child: const _ClipFlowBootstrap(),
    ),
  );
}

/// Wires cross-provider references that can't be done in MultiProvider alone.
class _ClipFlowBootstrap extends StatelessWidget {
  const _ClipFlowBootstrap();

  @override
  Widget build(BuildContext context) {
    // Connect ClipboardProvider to SettingsProvider after both are created
    final clipboard = context.read<ClipboardProvider>();
    final settings = context.read<SettingsProvider>();
    clipboard.setSettingsProvider(settings);
    return const ClipFlowApp();
  }
}
