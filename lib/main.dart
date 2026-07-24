import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  await controller.initialize();
  runApp(LorraineApp(controller: controller));
}

class LorraineApp extends StatelessWidget {
  const LorraineApp({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF17211B);
    const sage = Color(0xFF5E7B65);
    const paper = Color(0xFFF6F3EC);
    return MaterialApp(
      title: 'Lorraine',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: sage,
          brightness: Brightness.light,
          surface: paper,
        ),
        scaffoldBackgroundColor: paper,
        fontFamily: 'Helvetica Neue',
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Color(0xFFFCFAF5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFFE7E1D5)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      ),
      home: LorraineShell(controller: controller),
    );
  }
}
