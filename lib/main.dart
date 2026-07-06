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
      child: const ClipFlowApp(),
    ),
  );
}
